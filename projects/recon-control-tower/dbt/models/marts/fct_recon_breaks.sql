-- The open exception queue as of the latest reconciliation run.
--
-- One row per open item - true breaks AND in-transit reconciling items, with
-- the flag that separates them. Consumers that want only actionable work
-- filter on is_true_break; the close package needs both, because in-transit
-- dollars are a reconciling item on the bank rec.

with latest as (
    select max(run_date) as as_of_date from {{ ref('int_breaks__run_history') }}
)

select
    h.run_date                                              as as_of_date,
    h.break_id,
    h.break_source,
    h.break_code,
    h.break_family,
    h.is_true_break,
    h.flow_type,
    h.currency,
    h.side,
    h.severity,
    h.owner_team,
    h.exposure_cents,
    h.variance_cents,
    h.event_date,
    h.open_from,
    h.age_days,
    h.age_business_days,
    h.days_in_queue_bd,
    h.sla_clock_bd,
    h.sla_business_days,
    h.is_sla_breached,
    case
        when h.sla_clock_bd <= 1  then '0-1d'
        when h.sla_clock_bd <= 3  then '2-3d'
        when h.sla_clock_bd <= 7  then '4-7d'
        when h.sla_clock_bd <= 30 then '8-30d'
        else                           '30d+'
    end                                                     as aging_bucket,
    h.match_id,
    h.match_rule,
    h.event_ids,
    h.gl_account_code
from {{ ref('int_breaks__run_history') }} h
join latest on h.run_date = latest.as_of_date
