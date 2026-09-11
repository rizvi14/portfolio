-- Open true breaks as of the latest run, bucketed by SLA-clock age and
-- severity. The heat-map behind "where is the aged tail".

select
    as_of_date,
    flow_type,
    severity,
    aging_bucket,
    owner_team,
    count(*)                        as open_breaks,
    sum(exposure_cents)             as exposure_cents,
    sum(is_sla_breached::int)       as sla_breached,
    max(sla_clock_bd)               as oldest_bd
from {{ ref('fct_recon_breaks') }}
where is_true_break
group by all
