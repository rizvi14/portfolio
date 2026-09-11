-- The month-end package: what Accounting needs to sign the clearing accounts
-- off, on one row per rail per month.
--
-- Three things, in the order they get asked about:
--
--   1. Does the tie-out foot?  The bank reconciliation as of the last run of
--      the month, with every reconciling item named. unexplained_difference
--      must be zero - not small, zero. Anything else means the bridge itself
--      is broken and no number on the page can be trusted.
--
--   2. What is left in the clearing account, and why?  Split three ways: open
--      work, tolerated noise, and awaiting_correction - items already
--      explained and assigned whose correcting entry has not posted. The third
--      is the one that ages into account 1095 and the one an auditor opens
--      with, because it is the only category where nothing is scheduled to
--      happen next.
--
--   3. Did the population move the way it says it did?  Opening exceptions
--      plus opened minus closed must equal closing exceptions. This is the
--      roll-forward, and it is the difference between a report and a control:
--      without it, exceptions can quietly leave the queue - dropped by a
--      filter, orphaned by a renamed break code - and the closing count still
--      looks reasonable because nobody held it against the opening one.
--
-- The close month is cut on the last RUN date in the calendar month, not the
-- last calendar day, because a reconciliation that never ran cannot be
-- reported on. For a month that ends on a weekend the two differ, and using
-- the calendar date would silently report a Friday position as a Sunday one.
--
-- Sign-off status is advisory and deliberately conservative: it fails the
-- month for a broken bridge, and flags for review when the uncorrected
-- balance or the aged tail crosses materiality. It does not sign anything
-- off - a person does.

with close_dates as (
    select
        date_trunc('month', run_date)::date                      as close_month,
        max(run_date)                                            as close_date
    from {{ ref('fct_gl_tieout') }}
    group by all
),

-- the prior month's close, to anchor the roll-forward
periods as (
    select
        close_month,
        close_date,
        lag(close_date) over (order by close_month)              as prior_close_date
    from close_dates
),

tieout as (
    select p.close_month, p.close_date, p.prior_close_date, t.*
    from periods p
    join {{ ref('fct_gl_tieout') }} t on t.run_date = p.close_date
),

-- ------------------------------------------------------------- roll-forward
-- A roll-forward is a movement schedule between two balance dates, so
-- "opened" and "closed" are defined against those two dates and nothing else:
-- an item in the queue at close that was not there at the prior close was
-- opened; one that was there and is not now was closed. Defined that way the
-- identity holds by construction, which is the point - rollforward_gap is then
-- a real control on the queue rather than an artefact of how the window was
-- cut. Defining "closed" as "its last day in the queue fell in this month"
-- instead looks equivalent and is not: it silently drops every item that
-- opened and cleared between the two dates, and the gap it leaves grows with
-- throughput. That version is what this model shipped first, and it was off by
-- 93 items in the busiest month.
--
-- Leaving the queue is not the same as being corrected. An item leaves because
-- it was adjudicated or because it reclassified itself - a late settlement
-- that finally arrived. Either way the dollars stay in the clearing account
-- until an entry posts, which is what awaiting_correction_cents tracks.
membership as (
    select run_date, break_id, flow_type
    from {{ ref('int_breaks__run_history') }}
    where is_true_break
),

endpoints as (
    select
        p.close_month,
        m.break_id,
        m.flow_type,
        -- coalesce, not bare bool_or: in the first period prior_close_date is
        -- null, the comparison is null rather than false, and every "opened"
        -- filter downstream evaluates to null and counts nothing. The month
        -- then reports an opening balance of zero, no movement, and a closing
        -- balance out of thin air.
        coalesce(bool_or(m.run_date = p.close_date), false)       as at_close,
        coalesce(bool_or(m.run_date = p.prior_close_date), false) as at_prior
    from periods p
    join membership m on m.run_date in (p.close_date, p.prior_close_date)
    group by all
),

movement as (
    select
        close_month,
        flow_type,
        count(*) filter (where at_close and not at_prior)         as opened_breaks,
        count(*) filter (where at_prior and not at_close)         as closed_breaks
    from endpoints
    group by all
),

break_life as (
    select
        break_id,
        flow_type,
        min(run_date)                                            as first_open_run,
        max(run_date)                                            as last_open_run
    from membership
    group by all
),

-- informational, and deliberately outside the identity: exceptions that were
-- raised and cleared between the two balance dates never touch either
-- endpoint, so a queue that looks quiet at month end can still have been
-- working hard all month.
churn as (
    select
        p.close_month,
        b.flow_type,
        count(*)                                                 as raised_and_cleared_in_period
    from periods p
    join break_life b
        on  b.first_open_run >  coalesce(p.prior_close_date, DATE '1900-01-01')
        and b.last_open_run  <  p.close_date
    group by all
),

open_at as (
    select
        p.close_month,
        h.flow_type,
        count(*)                                                 as open_breaks,
        sum(h.exposure_cents)                                    as open_exposure_cents,
        max(h.sla_clock_bd)                                      as oldest_open_break_bd,
        count(*) filter (where h.is_sla_breached)                as sla_breached,
        count(*) filter (where h.severity = 'critical')          as open_critical
    from periods p
    join {{ ref('int_breaks__run_history') }} h
        on h.run_date = p.close_date and h.is_true_break
    group by all
),

opened_at_prior as (
    select
        p.close_month,
        m.flow_type,
        count(*)                                                 as opening_breaks
    from periods p
    join membership m on m.run_date = p.prior_close_date
    group by all
)

select
    t.close_month,
    t.close_date,
    t.flow_type,

    -- 1. the tie-out
    t.bank_balance_cents,
    t.in_transit_cents,
    t.unmatched_internal_cents,
    t.at_bank_awaiting_book_cents,
    t.unmatched_external_cents,
    t.variance_over_tolerance_cents,
    t.tolerated_variance_cents,
    t.gl_balance_cents,
    t.difference_cents,
    t.unexplained_difference_cents,

    -- 2. what is sitting in the clearing account
    t.open_queue_cents,
    t.awaiting_correction_cents,
    coalesce(o.open_breaks, 0)                                   as open_breaks,
    coalesce(o.open_exposure_cents, 0)                           as open_exposure_cents,
    coalesce(o.oldest_open_break_bd, 0)                          as oldest_open_break_bd,
    coalesce(o.sla_breached, 0)                                  as sla_breached,
    coalesce(o.open_critical, 0)                                 as open_critical,

    -- 3. the roll-forward: opening + opened - closed = closing
    coalesce(p.opening_breaks, 0)                                as opening_breaks,
    coalesce(m.opened_breaks, 0)                                 as opened_breaks,
    coalesce(m.closed_breaks, 0)                                 as closed_breaks,
    coalesce(ch.raised_and_cleared_in_period, 0)                 as raised_and_cleared_in_period,
    coalesce(p.opening_breaks, 0)
        + coalesce(m.opened_breaks, 0)
        - coalesce(m.closed_breaks, 0)
        - coalesce(o.open_breaks, 0)                             as rollforward_gap,

    case
        when t.unexplained_difference_cents <> 0                            then 'blocked - bridge does not foot'
        when abs(t.awaiting_correction_cents) > {{ var('close_materiality_cents') }}
                                                                            then 'review - uncorrected balance over materiality'
        when coalesce(o.open_critical, 0) > 0                               then 'review - critical exception open at close'
        when coalesce(o.sla_breached, 0) > 0                                then 'review - exceptions past SLA at close'
        else                                                                     'clean'
    end                                                          as close_status
from tieout t
left join open_at o          on o.close_month = t.close_month and o.flow_type = t.flow_type
left join opened_at_prior p  on p.close_month = t.close_month and p.flow_type = t.flow_type
left join movement m         on m.close_month = t.close_month and m.flow_type = t.flow_type
left join churn ch           on ch.close_month = t.close_month and ch.flow_type = t.flow_type
order by t.close_month, t.flow_type
