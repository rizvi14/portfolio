-- Break taxonomy as a dimension, straight from the reviewed seed.

select
    break_code,
    break_family,
    flow_scope,
    display_name,
    is_true_break,
    default_severity,
    owner_team,
    sla_business_days,
    typical_root_cause,
    gl_treatment
from {{ ref('seed_break_taxonomy') }}
