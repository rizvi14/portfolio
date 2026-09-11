-- What each rail ACTUALLY does, measured - versus what the contract says it
-- should do.
--
-- The settlement window in dbt_project.yml is a policy number: ACH T+1, card
-- T+2, wire same day. Real arrivals have a tail the policy number does not
-- describe. An ACH that misses the afternoon cutoff rides to the next file; a
-- card refund settles the second half a day after the first. Neither is a
-- defect, but a queue that calls "late" straight off the policy number raises
-- both - and an exception queue that is mostly noise is one an analyst stops
-- reading.
--
-- So the investigation threshold is calibrated from observed behaviour:
--
--     threshold = clamp( p99 observed arrival lag,
--                        floor   = policy window + grace,
--                        ceiling = investigation_threshold_ceiling_bd )
--
-- Three things make this honest rather than circular:
--
--   1. It reads only CLEANLY MATCHED pairs - items the waterfall resolved on
--      its own. No ground truth, nothing an analyst could not compute from a
--      production warehouse on day one.
--
--   2. The percentile has to sit above the defect rate or the threshold learns
--      the defect. That is a per-rail judgement, not a global constant, and it
--      is why observed_pairs and the tail columns are published here: on ACH
--      the legitimate slow tail is ~1.7% of pairs and the late-settlement
--      defect ~0.7%, so p99 lands between them. If those rates converge the
--      calibration stops working and this model is where you would see it.
--
--   3. The ceiling is the control. Without it a degrading rail quietly widens
--      its own definition of "on time" until nothing is ever late - the
--      failure mode of every self-tuning threshold. p99 pushing into the
--      ceiling is a signal about the RAIL, not a reason to raise the ceiling;
--      threshold_is_capped is the flag that says so.
--
-- The floor matters too: a rail behaving perfectly this month must not tighten
-- the threshold below the contractual window, or the first normal-but-slow
-- settlement becomes a break.
--
-- SECOND THRESHOLD - partial completion. Some settlements legitimately arrive
-- in more than one piece. Age from the transaction date cannot separate those
-- from a settlement that never finished, because the last leg of a normal
-- split lands later than the whole of a normal single. What separates them is
-- that a split has ALREADY PAID something: one leg is sitting in the file.
-- That is observable on the run date - no future knowledge - so it gets its
-- own clock, measured leg-to-leg, and its own queue state.

with clean_matches as (
    select
        flow_type,
        external_count,
        {{ business_days_between('internal_event_date', 'external_available_from') }} as arrival_lag_bd,
        {{ business_days_between('external_first_available_from', 'external_available_from') }} as leg_gap_bd
    from {{ ref('int_matches__all') }}
    where is_within_tolerance
),

arrival as (
    select
        flow_type,
        count(*)                                            as observed_pairs,
        quantile_cont(arrival_lag_bd, 0.50)                 as lag_p50_bd,
        quantile_cont(arrival_lag_bd, 0.95)                 as lag_p95_bd,
        quantile_cont(arrival_lag_bd, 0.99)                 as lag_p99_bd,
        max(arrival_lag_bd)                                 as lag_max_bd
    from clean_matches
    group by all
),

-- leg-to-leg gap on settlements that arrived in pieces
splits as (
    select
        flow_type,
        count(*)                                            as observed_splits,
        quantile_cont(leg_gap_bd, 0.99)                     as leg_gap_p99_bd,
        max(leg_gap_bd)                                     as leg_gap_max_bd
    from clean_matches
    where external_count > 1
    group by all
),

bounded as (
    select
        a.*,
        coalesce(s.observed_splits, 0)                      as observed_splits,
        coalesce(s.leg_gap_p99_bd, 0)                       as leg_gap_p99_bd,
        coalesce(s.leg_gap_max_bd, 0)                       as leg_gap_max_bd,
        {{ settlement_window_days('a.flow_type') }}         as policy_window_bd,
        {{ settlement_window_days('a.flow_type') }}
            + {{ var('timing_grace_business_days') }}       as floor_bd,
        {{ var('investigation_threshold_ceiling_bd') }}     as ceiling_bd,
        greatest(
            {{ settlement_window_days('a.flow_type') }} + {{ var('timing_grace_business_days') }},
            ceil(a.lag_p99_bd)::int
        )                                                   as uncapped_threshold_bd
    from arrival a
    left join splits s on s.flow_type = a.flow_type
)

select
    flow_type,
    observed_pairs,
    policy_window_bd,
    lag_p50_bd,
    lag_p95_bd,
    lag_p99_bd,
    lag_max_bd,
    floor_bd,
    ceiling_bd,
    -- An item still open at this age has used up the whole window the rail
    -- actually meets and has not arrived. Strictly: an arrival at lag L is
    -- last seen open at age L-1, so a threshold of T lets every arrival at
    -- lag <= T through untouched and flags everything slower.
    least(uncapped_threshold_bd, ceiling_bd)                as investigation_threshold_bd,
    uncapped_threshold_bd > ceiling_bd                      as threshold_is_capped,
    -- how far the rail's tail runs past its own contract. Consistently > 0 is
    -- a conversation to have with the partner, not a number to absorb.
    ceil(lag_p99_bd)::int - policy_window_bd                as tail_over_policy_bd,
    observed_splits,
    leg_gap_p99_bd,
    leg_gap_max_bd,
    least(greatest(ceil(leg_gap_p99_bd)::int, 1), ceiling_bd)
                                                            as partial_completion_threshold_bd
from bounded
order by flow_type
