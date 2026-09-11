-- The four-column bank reconciliation, per rail, for every run date.
--
--     balance per bank
--     + items booked but not yet at the bank        (in transit)
--     + items booked with nothing at the bank       (internal orphans)
--     - items at the bank not yet booked            (external orphans / early arrivals)
--     + amount variances on matched pairs
--     + differences absorbed by tolerance
--     = balance per books
--
-- The bridge is built from MATCH STATE, not from the exception queue, and the
-- distinction matters more than it looks.
--
-- An exception leaves the queue when someone adjudicates it. It does not leave
-- the clearing account: the dollars sit there until a correcting entry is
-- posted. Building the bridge off open items therefore produces a tie-out that
-- stops footing the moment the team starts working the queue, which is exactly
-- backwards. Every event visible as of the run date is instead classified by
-- whether its match had COMPLETED by then, which is a fact about the data
-- rather than a fact about anyone's workflow:
--
--     GL - bank  =  (open internal) - (open external) + (variance on completed)
--
-- That is an identity, so unexplained_difference_cents is zero by
-- construction, and the control on it is a footing check: it catches a join
-- that fans out, a leg counted twice, an event that belongs to no bucket. A
-- close package that does not foot is not a close package.
--
-- The number with actual information in it is awaiting_correction_cents: the
-- slice of the difference that is neither open work nor tolerated noise -
-- items already explained and assigned, still sitting in the clearing account
-- because nothing has been posted to clear them. That is the balance that ages
-- into account 1095 and the one an auditor asks about first.
--
-- SCOPE. This build models the tie-out only. There are no journal entries and
-- no suspense mechanics, so resolving a break here changes its workflow state
-- and not the ledger. In production the correcting entry would post, the GL
-- balance would move, and awaiting_correction_cents would fall to zero as a
-- matter of course rather than as a matter of attention.

with spine as (
    select distinct run_date from {{ ref('int_breaks__run_history') }}
),

events as (
    select
        event_id,
        side,
        flow_type,
        signed_amount_cents,
        available_from
    from {{ ref('int_recon_events__unioned') }}
),

-- every leg, with the date its match completed (null if it never matched)
legs as (
    select unnest(internal_event_ids) as event_id, matched_on_date
    from {{ ref('int_matches__all') }}
    union all
    select unnest(external_event_ids), matched_on_date
    from {{ ref('int_matches__all') }}
),

visible as (
    select
        s.run_date,
        e.flow_type,
        e.side,
        e.signed_amount_cents,
        l.matched_on_date is not null
            and l.matched_on_date <= s.run_date                  as match_completed,
        l.matched_on_date is null                                as never_matched
    from spine s
    join events e on e.available_from <= s.run_date
    left join legs l using (event_id)
),

balances as (
    select
        run_date,
        flow_type,
        sum(signed_amount_cents) filter (where side = 'internal')            as gl_balance_cents,
        sum(signed_amount_cents) filter (where side = 'external')            as bank_balance_cents,
        -- booked, counterpart identified, not yet arrived at the bank
        sum(signed_amount_cents) filter (
            where side = 'internal' and not match_completed and not never_matched) as in_transit_cents,
        -- booked, nothing at the bank at all
        sum(signed_amount_cents) filter (
            where side = 'internal' and never_matched)                       as unmatched_internal_cents,
        -- at the bank ahead of the ledger (its pair completes on a later run)
        sum(signed_amount_cents) filter (
            where side = 'external' and not match_completed and not never_matched) as at_bank_awaiting_book_cents,
        -- at the bank with nothing on the books
        sum(signed_amount_cents) filter (
            where side = 'external' and never_matched)                       as unmatched_external_cents
    from visible
    group by all
),

-- variances on pairs that had completed by the run date, split at the
-- tolerance line. Everything under it is a difference the policy chose to
-- stop looking at - which does not make it disappear from the clearing
-- account, it makes it accumulate there quietly.
variances as (
    select
        s.run_date,
        m.flow_type,
        sum(m.internal_amount_cents - m.external_amount_cents)
            filter (where not m.is_within_tolerance)             as variance_over_tolerance_cents,
        sum(m.internal_amount_cents - m.external_amount_cents)
            filter (where m.is_within_tolerance)                 as tolerated_variance_cents
    from spine s
    join {{ ref('int_matches__all') }} m on m.matched_on_date <= s.run_date
    group by all
),

-- what the team can still act on, as of this run
queue as (
    select
        run_date,
        flow_type,
        sum(gl_impact_cents)                                     as open_queue_cents,
        count(*) filter (where is_true_break)                    as open_breaks
    from {{ ref('int_breaks__run_history') }}
    group by all
),

assembled as (
    select
        b.run_date,
        b.flow_type,
        coalesce(b.bank_balance_cents, 0)                        as bank_balance_cents,
        coalesce(b.gl_balance_cents, 0)                          as gl_balance_cents,
        coalesce(b.in_transit_cents, 0)                          as in_transit_cents,
        coalesce(b.unmatched_internal_cents, 0)                  as unmatched_internal_cents,
        coalesce(b.at_bank_awaiting_book_cents, 0)               as at_bank_awaiting_book_cents,
        coalesce(b.unmatched_external_cents, 0)                  as unmatched_external_cents,
        coalesce(v.variance_over_tolerance_cents, 0)             as variance_over_tolerance_cents,
        coalesce(v.tolerated_variance_cents, 0)                  as tolerated_variance_cents,
        coalesce(q.open_queue_cents, 0)                          as open_queue_cents,
        coalesce(q.open_breaks, 0)                               as open_breaks
    from balances b
    left join variances v using (run_date, flow_type)
    left join queue q using (run_date, flow_type)
)

select
    run_date,
    flow_type,
    bank_balance_cents,
    in_transit_cents,
    unmatched_internal_cents,
    at_bank_awaiting_book_cents,
    unmatched_external_cents,
    variance_over_tolerance_cents,
    tolerated_variance_cents,
    gl_balance_cents,
    gl_balance_cents - bank_balance_cents                        as difference_cents,
    -- the footing check: everything above must add up to the books
    gl_balance_cents - (
        bank_balance_cents
        + in_transit_cents
        + unmatched_internal_cents
        - at_bank_awaiting_book_cents
        - unmatched_external_cents
        + variance_over_tolerance_cents
        + tolerated_variance_cents
    )                                                            as unexplained_difference_cents,
    open_queue_cents,
    open_breaks,
    -- identified, adjudicated, and still in the clearing account because no
    -- correcting entry has been posted. Ages into account 1095.
    gl_balance_cents - bank_balance_cents
        - open_queue_cents
        - tolerated_variance_cents                               as awaiting_correction_cents
from assembled
order by run_date, flow_type
