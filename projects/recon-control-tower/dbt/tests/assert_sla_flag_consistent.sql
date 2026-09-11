-- The SLA clock and the breach flag, recomputed from first principles.
--
-- is_sla_breached is what the queue is sorted by, what escalates, and what
-- gets reported to the partner. The clock behind it is not the obvious one:
-- it starts when the item became ACTIONABLE, not at the transaction date,
-- because nobody can work an ACH orphan before its settlement window has
-- elapsed. Both failure directions are bad - a flag that fires early trains
-- analysts to ignore it, a flag that fires late hides an aged item until it
-- is a write-off.
--
-- So this does not re-read the stored clock and compare it to itself. It
-- rebuilds it from the raw inputs - the date the item entered the queue, the
-- run date, the threshold, and whether the item is age-dependent - and
-- asserts the model arrived at the same number, then that the flag follows
-- from it. Three independent ways to get it wrong, one check.

with recomputed as (
    select
        h.run_date,
        h.break_id,
        h.break_code,
        h.open_from,
        h.is_true_break,
        h.investigation_threshold_bd,
        h.days_in_queue_bd,
        h.sla_clock_bd,
        h.sla_business_days,
        h.is_sla_breached,
        {{ business_days_between('h.open_from', 'h.run_date') }}    as expected_days_in_queue_bd,
        greatest(0, {{ business_days_between('h.open_from', 'h.run_date') }}
            - case when c.is_age_dependent then h.investigation_threshold_bd else 0 end)
                                                                    as expected_sla_clock_bd
    from {{ ref('int_breaks__run_history') }} h
    join {{ ref('int_breaks__candidates') }} c using (break_id)
)

select *
from recomputed
where days_in_queue_bd is distinct from expected_days_in_queue_bd
   or sla_clock_bd     is distinct from expected_sla_clock_bd
   or is_sla_breached  is distinct from (coalesce(is_true_break, false)
                                         and expected_sla_clock_bd > sla_business_days)
   or sla_clock_bd < 0
