-- No event may be matched twice.
--
-- The waterfall is a cascade: each tier anti-joins everything the tiers above
-- it consumed. If that anti-join is ever broken - a new tier added without
-- one, a join that fans out - the same ledger entry gets paired twice and the
-- match rate goes UP while the reconciliation gets worse. Double-counting
-- inflates every number on the dashboard in the reassuring direction, which
-- is precisely why it needs a hard control rather than a review.
--
-- Fails with the offending event and the matches that claim it.

with claimed as (
    select unnest(internal_event_ids) as event_id, match_id, match_tier
    from {{ ref('int_matches__all') }}
    union all
    select unnest(external_event_ids), match_id, match_tier
    from {{ ref('int_matches__all') }}
)

select
    event_id,
    count(*)            as times_matched,
    list(match_id)      as claimed_by,
    list(match_tier)    as tiers
from claimed
group by event_id
having count(*) > 1
