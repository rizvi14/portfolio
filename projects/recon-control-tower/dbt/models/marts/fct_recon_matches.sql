-- Every matched group, one row per match, with the tier that made it and
-- whether the amounts agreed. The audit trail for "why did these two records
-- get paired".

select
    match_id,
    match_tier,
    match_rule,
    flow_type,
    currency,
    internal_event_ids,
    external_event_ids,
    internal_count,
    external_count,
    internal_amount_cents,
    external_amount_cents,
    variance_cents,
    is_within_tolerance,
    had_timing_gap,
    timing_gap_days,
    internal_event_date,
    external_event_date,
    internal_available_from,
    external_available_from,
    matched_on_date
from {{ ref('int_matches__all') }}
