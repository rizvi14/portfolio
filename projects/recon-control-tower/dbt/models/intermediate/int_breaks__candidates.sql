-- Every potential exception, with the window during which it was open.
--
-- Three sources feed this, and keeping them distinct is what lets the
-- run-history model replay the queue as of any date without snapshots:
--
--   orphan     an item the waterfall never paired. Open from the day it
--              became visible; never closes in this dataset.
--   variance   a pair the waterfall linked whose amounts disagree beyond
--              tolerance. Open from the day BOTH sides were visible.
--   timing     a pair that DID reconcile cleanly, but whose two sides became
--              visible on different days. It was an open item in every run
--              between those dates, then closed itself. Most of these are
--              in-transit and not breaks; the ones that outlive the
--              settlement window are.
--
-- Classification here is STATIC (what the item is). Whether it counts as a
-- break on a given run date can depend on its age - that is decided in
-- int_breaks__run_history.

with taxonomy as (
    select * from {{ ref('seed_break_taxonomy') }}
),

-- ---------------------------------------------------------------- orphans
orphans as (
    select
        'ORPH-' || event_id                                 as break_id,
        'orphan'                                            as break_source,
        flow_type,
        currency,
        side,
        case
            when side = 'internal' and same_side_ref_count > 1           then 'duplicate_internal'
            when side = 'external' and hint_is_redelivered               then 'duplicate_external'
            when side = 'external' and hint_return_code is not null      then 'return_unlinked'
            when side = 'external' and hint_bai_code = '555'             then 'bank_adjustment'
            when side = 'external' and hint_is_dispute_leg               then 'chargeback_pair'
            when side = 'internal'                                       then 'missing_external'
            else                                                              'missing_internal'
        end                                                 as break_code_static,
        -- internal orphans may still be in transit as of an early run date;
        -- the run-history model resolves that by age
        side = 'internal'                                   as is_age_dependent,
        abs(signed_amount_cents)                            as exposure_cents,
        signed_amount_cents                                 as variance_cents,
        event_date,
        available_from                                      as open_from,
        null::date                                          as open_until,
        null::date                                          as partial_from,
        [event_id]                                          as event_ids,
        null::varchar                                       as match_id,
        null::varchar                                       as match_rule,
        counterparty_norm,
        gl_account_code
    from {{ ref('int_unmatched') }}
),

-- --------------------------------------------------------------- variances
matches as (
    select * from {{ ref('int_matches__all') }}
),

variances as (
    select
        'VAR-' || match_id                                  as break_id,
        'variance'                                          as break_source,
        flow_type,
        currency,
        'pair'                                              as side,
        case
            -- aggregate groups where one side is a whole multiple of the other
            when match_rule = 'aggregate_ref' and internal_count > external_count
                 and abs(internal_amount_cents) between abs(external_amount_cents) * 1.98 and abs(external_amount_cents) * 2.02
                                                                                    then 'duplicate_internal'
            when match_rule = 'aggregate_ref' and external_count > internal_count
                 and abs(external_amount_cents) between abs(internal_amount_cents) * 1.98 and abs(internal_amount_cents) * 2.02
                                                                                    then 'duplicate_external'
            -- digit transposition: both amounts are the same multiset of digits
            when list_sort(string_split(abs(internal_amount_cents)::varchar, ''))
               = list_sort(string_split(abs(external_amount_cents)::varchar, ''))
                                                                                    then 'transposition'
            -- card: settled short of booked by a fee-shaped ratio (~1.8% + 10c)
            when flow_type = 'card'
                 and variance_cents * sign(internal_amount_cents) > 0
                 and abs(variance_cents) / nullif(abs(internal_amount_cents), 0) between 0.015 and 0.045
                                                                                    then 'fee_interchange'
            -- card: settled differs by a tip (15-22% over) or partial capture (20-50% under)
            when flow_type = 'card'
                 and abs(variance_cents) / nullif(abs(internal_amount_cents), 0) between 0.10 and 0.55
                                                                                    then 'auth_capture'
            -- wire: a small round fee lifted in transit
            when flow_type = 'wire' and abs(variance_cents) between 1000 and 5000
                                                                                    then 'fee_lifting'
            else                                                                         'amount_variance_other'
        end                                                 as break_code_static,
        false                                               as is_age_dependent,
        abs(variance_cents)                                 as exposure_cents,
        variance_cents,
        internal_event_date                                 as event_date,
        matched_on_date                                     as open_from,
        null::date                                          as open_until,
        null::date                                          as partial_from,
        list_concat(internal_event_ids, external_event_ids) as event_ids,
        match_id,
        match_rule,
        null::varchar                                       as counterparty_norm,
        null::varchar                                       as gl_account_code
    from matches
    where not is_within_tolerance
),

-- ------------------------------------------------------------------ timing
timing as (
    select
        'TIM-' || match_id                                  as break_id,
        'timing'                                            as break_source,
        flow_type,
        currency,
        'pair'                                              as side,
        'in_transit'                                        as break_code_static,
        true                                                as is_age_dependent,
        abs(internal_amount_cents)                          as exposure_cents,
        0                                                   as variance_cents,
        internal_event_date                                 as event_date,
        least(internal_available_from, external_available_from)    as open_from,
        greatest(internal_available_from, external_available_from) as open_until,
        -- a settlement that arrives in pieces has already paid something. The
        -- first leg is visible in the file on this date, so the run-history
        -- model can use it without knowing anything about the future.
        case when external_count > 1 then external_first_available_from end
                                                            as partial_from,
        list_concat(internal_event_ids, external_event_ids) as event_ids,
        match_id,
        match_rule,
        null::varchar                                       as counterparty_norm,
        null::varchar                                       as gl_account_code
    from matches
    where is_within_tolerance and had_timing_gap
),

unioned as (
    select * from orphans
    union all
    select * from variances
    union all
    select * from timing
),

enriched as (
    select
        u.*,
        {{ settlement_window_days('u.flow_type') }}         as settlement_window_days,
        t.break_family,
        t.is_true_break                                     as is_true_break_static,
        t.owner_team,
        t.sla_business_days,
        -- severity: the taxonomy default, escalated by exposure
        case
            when not t.is_true_break                                            then 'none'
            when u.exposure_cents >= crit.exposure_floor_cents                   then 'critical'
            when u.exposure_cents >= high.exposure_floor_cents
                 and t.default_severity in ('medium', 'low')                     then 'high'
            else t.default_severity
        end                                                 as severity
    from unioned u
    left join taxonomy t on t.break_code = u.break_code_static
    cross join (select exposure_floor_cents from {{ ref('seed_severity_matrix') }} where severity = 'critical') crit
    cross join (select exposure_floor_cents from {{ ref('seed_severity_matrix') }} where severity = 'high') high
),

-- ------------------------------------------------------------- resolution
-- The engine FINDS exceptions; closing them is a human workflow that lives in
-- a case-management system in production. This dataset has no humans, so
-- resolution is simulated: a deterministic hash of the break id draws a
-- working lag straddling each severity's SLA, and ~3% of items never close, which keeps
-- an aged tail in the queue for the SLA controls to catch. Stated openly in
-- the README - it is the one place the pipeline models behaviour rather than
-- observes it.
resolved as (
    select
        *,
        hash(break_id) % 100                                as _h,
        -- lags straddle the SLA for each severity, so the queue carries a
        -- realistic mix of within-SLA and breached items rather than all of one
        case severity
            when 'critical' then 1 + hash(break_id) % 2      -- SLA 1
            when 'high'     then 1 + hash(break_id) % 4      -- SLA 2
            when 'medium'   then 2 + hash(break_id) % 5      -- SLA 3
            when 'low'      then 3 + hash(break_id) % 8      -- SLA 5
        end                                                 as resolution_lag_business_days
    from enriched
)

select
    * exclude (_h, open_until),
    case
        when open_until is not null                         then open_until          -- timing: self-closed
        when not is_true_break_static                       then null
        when _h < 3                                         then null                -- stuck (~3%)
        else open_from
              + interval (case when is_age_dependent then settlement_window_days + 2 else 0 end) day
              + interval (resolution_lag_business_days * 7 / 5) day            -- calendar-day approximation
    end::date                                               as open_until
from resolved
