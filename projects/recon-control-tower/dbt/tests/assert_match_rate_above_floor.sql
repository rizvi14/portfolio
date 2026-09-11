-- The match rate on matured items must hold its floor, every run, every rail.
--
-- Two deliberate choices about how this is measured:
--
--   MATURED ONLY. An item that has not had a full settlement window cannot
--   have matched yet. Including it drags the rate down on exactly the days
--   volume spikes, and the usual reaction - widening the window until the
--   alert stops - breaks the control instead of fixing it.
--
--   PER RAIL, not just overall. Card is 70% of volume here, so a total
--   collapse of wire matching moves the blended rate by a fraction of a
--   point. The per-flow floor is what actually catches a broken rail.
--
-- The warm-up guard exists because the first runs in the replay window have a
-- handful of matured items and one unmatched item swings the rate several
-- points. It is a statistical floor on the denominator, not a way to exclude
-- inconvenient days: it is expressed in item count, not in dates.

with daily as (
    select
        run_date,
        flow_type,
        items_matured,
        items_matched,
        match_rate
    from {{ ref('agg_recon_daily') }}
    where items_matured >= 50
)

select
    run_date,
    flow_type,
    items_matured,
    items_matched,
    match_rate,
    {{ var('match_rate_floor_by_flow') }} as floor
from daily
where match_rate < {{ var('match_rate_floor_by_flow') }}
