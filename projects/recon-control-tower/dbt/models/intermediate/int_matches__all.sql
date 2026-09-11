-- Every match from every tier, with the variance judged against tolerance.
--
-- A match is not the same as a clean match. Tiers 1 and 2 join on reference
-- and can pair two records whose amounts disagree; that pair stays LINKED
-- (which is what makes the root cause findable) but is flagged as a variance
-- exception when the gap exceeds tolerance.

with unioned as (
    select * from {{ ref('int_matches__tier1_exact') }}
    union all
    select * from {{ ref('int_matches__tier2_aggregate') }}
    union all
    select * from {{ ref('int_matches__tier3_attribute') }}
    union all
    select * from {{ ref('int_matches__tier4_tolerance') }}
)

select
    *,
    {{ amount_within_tolerance('internal_amount_cents', 'external_amount_cents', 'flow_type') }}
        as is_within_tolerance,
    -- Reconciling-item signal: both sides were visible on different days.
    -- The item was "open" in every run between those two dates.
    internal_available_from <> external_available_from                  as had_timing_gap,
    date_diff('day', least(internal_available_from, external_available_from),
                     greatest(internal_available_from, external_available_from))
                                                                        as timing_gap_days
from unioned
