-- The exception queue as it stood on every daily reconciliation run.
--
-- This is the snapshot replacement. Rather than persisting dbt snapshots of
-- a mutable table, every candidate carries its open window, so the queue as
-- of any run date is a join against a date spine. It is cheaper, fully
-- deterministic, and it replays history from a cold clone - none of which a
-- snapshot table can do.
--
-- Classification is resolved AS OF the run date: an internal item three days
-- unmatched is "in transit" on a rail with a five-day window and a "late
-- settlement" break on a rail with a one-day window. The same item, the same
-- run, a different verdict - because the verdict depends on the clock.
--
-- Two clocks, and both are business-day clocks:
--
--   age_business_days   how long since the transaction. Drives classification.
--   sla_clock_bd        how long the item has been ACTIONABLE. An internal
--                       orphan is not work anyone can do until its settlement
--                       window has elapsed, so those days do not count against
--                       the owning team. Starting the SLA at transaction date
--                       instead is the single fastest way to make an
--                       exception queue look permanently on fire.

{% set history_days = var('recon_history_days') %}

with bounds as (
    -- "Today" is the last day the ledger posted anything. Using the latest
    -- external arrival instead would push the clock weeks past the last real
    -- activity (a 20-day representment does exactly that) and nothing would
    -- ever look in transit.
    select max(event_date) as as_of_date
    from {{ ref('int_recon_events__unioned') }}
    where side = 'internal'
),

spine as (
    select cast(d as date) as run_date
    from bounds,
         generate_series(
             as_of_date - interval ({{ history_days * 2 }}) day,
             as_of_date,
             interval 1 day
         ) as g(d)
    where dayofweek(cast(d as date)) between 1 and 5
    qualify row_number() over (order by d desc) <= {{ history_days }}
),

candidates as (
    select * from {{ ref('int_breaks__candidates') }}
),

taxonomy as (
    select * from {{ ref('seed_break_taxonomy') }}
),

-- The age at which an unmatched item stops being "still arriving" and starts
-- being an exception. Calibrated per rail from observed settlement behaviour
-- rather than assumed from the policy window - see int_settlement_profile.
threshold as (
    select flow_type, investigation_threshold_bd, partial_completion_threshold_bd
    from {{ ref('int_settlement_profile') }}
),

open_as_of as (
    select
        s.run_date,
        c.*,
        coalesce(th.investigation_threshold_bd,
                 c.settlement_window_days + {{ var('timing_grace_business_days') }})
                                                                                as investigation_threshold_bd,
        coalesce(th.partial_completion_threshold_bd, 1)                         as partial_completion_threshold_bd,
        c.partial_from is not null and c.partial_from <= s.run_date             as is_partially_settled,
        date_diff('day', c.event_date, s.run_date)                              as age_days,
        {{ business_days_between('c.event_date', 's.run_date') }}               as age_business_days,
        {{ business_days_between('c.open_from', 's.run_date') }}                as days_in_queue_bd
    from spine s
    join candidates c
        on  c.open_from <= s.run_date
        and (c.open_until is null or s.run_date < c.open_until)
    left join threshold th on th.flow_type = c.flow_type
),

classified as (
    select
        *,
        case
            -- still inside the rail's measured arrival window: the record has
            -- not had its chance to show up yet, so there is nothing to
            -- investigate. Strict "<" because an arrival at lag L is last seen
            -- open at age L-1; an item still sitting here at age = threshold
            -- has outlived the window the rail actually meets.
            when is_age_dependent and age_business_days < investigation_threshold_bd
                                                                                then 'in_transit'
            -- money has already moved against this item and the remainder is
            -- inside the observed leg-to-leg gap. Not in transit (something
            -- arrived), not late (the rest is not due yet) - its own state, so
            -- that a queue full of these is visibly different from a queue
            -- full of silence.
            when is_age_dependent and is_partially_settled
                 and {{ business_days_between('partial_from', 'run_date') }} < partial_completion_threshold_bd
                                                                                then 'partially_settled'
            when is_age_dependent and break_source = 'timing'                   then 'timing_late'
            else break_code_static
        end                                                                     as break_code,
        -- the SLA clock only starts once the item is actionable
        greatest(0, days_in_queue_bd
            - case when is_age_dependent then investigation_threshold_bd else 0 end)
                                                                                as sla_clock_bd
    from open_as_of
)

select
    c.run_date,
    c.break_id,
    c.break_source,
    c.break_code,
    t.break_family,
    t.is_true_break,
    c.flow_type,
    c.currency,
    c.side,
    c.exposure_cents,
    c.variance_cents,
    c.event_date,
    c.open_from,
    c.open_until,
    c.age_days,
    c.age_business_days,
    c.days_in_queue_bd,
    c.investigation_threshold_bd,
    c.is_partially_settled,
    c.sla_clock_bd,
    c.event_ids,
    c.match_id,
    c.match_rule,
    c.gl_account_code,
    t.owner_team,
    case when t.is_true_break then c.severity else 'none' end           as severity,
    t.sla_business_days,
    t.is_true_break and c.sla_clock_bd > t.sla_business_days            as is_sla_breached
from classified c
left join taxonomy t on t.break_code = c.break_code
