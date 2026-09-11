-- The false-positive trap.
--
-- The generator plants settlements that are slow but entirely normal - an ACH
-- riding the next file, a refund that settles in two legs. They are unmatched
-- on some run dates and they are NOT defects. A reconciliation that pages
-- someone for these is worse than no reconciliation, because analysts learn to
-- skim the queue, and the day a real break appears it is sitting in a list of
-- things everyone has been trained to ignore.
--
-- The control needs no ground truth. Every timing candidate carries the date
-- its counterpart actually landed, so the true arrival lag is knowable after
-- the fact, and the rule is: an item that arrived inside the CONTRACTUAL
-- window plus grace must never have been called late while it was open.
--
-- The reference is deliberately the policy number from dbt_project.yml, not
-- the calibrated investigation threshold the classifier used. A control that
-- grades a decision against the same knob that made the decision cannot fail:
-- tighten the knob and the control tightens with it, and both agree all the
-- way down. The first version of this test did exactly that and passed
-- happily with the threshold forced to one business day - a setting that
-- raises hundreds of normal settlements as breaks. Policy is the fixed point
-- the calibration is allowed to move around; it is the only honest anchor.
--
-- Fails with the item, its true arrival lag, and the window it beat.

with timing_items as (
    select
        h.break_id,
        h.flow_type,
        min(h.event_date)                                    as event_date,
        max(h.open_until)                                    as arrived_on,
        max(h.investigation_threshold_bd)                    as threshold_used_bd,
        max(h.age_business_days)                             as max_age_bd_while_open,
        count(*) filter (where h.break_code = 'timing_late') as runs_called_late
    from {{ ref('int_breaks__run_history') }} h
    where h.break_source = 'timing'
      and h.open_until is not null
    group by h.break_id, h.flow_type
),

judged as (
    select
        *,
        {{ business_days_between('event_date', 'arrived_on') }} as arrival_lag_bd,
        {{ settlement_window_days('flow_type') }}
            + {{ var('timing_grace_business_days') }}           as contractual_window_bd
    from timing_items
)

select *
from judged
where arrival_lag_bd <= contractual_window_bd
  and runs_called_late > 0
