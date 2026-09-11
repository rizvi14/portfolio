-- One row per reconciliation run x funds flow: the numbers a recon lead looks
-- at every morning, in the order they should look at them.
--
--   1. unexplained exposure   dollars in open TRUE breaks. The headline. A
--                             99.5% match rate with $2M unexplained is a
--                             failing reconciliation.
--   2. oldest open break      the aged tail is where losses hide
--   3. match rate             on MATURED items only - those that have had a
--                             full settlement window to arrive. Measuring it
--                             on items that could not have settled yet is the
--                             most common self-inflicted recon wound.
--   4. tier composition       how much of the match rate is doing real work
--                             (tier 1) versus fuzzy rules that need watching
--
-- Match rate counts an item as matched if the waterfall PAIRED it, even when
-- the amounts disagree; the variance is a separate exception. That is why
-- "matched" and "clean" are reported side by side.

with spine as (
    select distinct run_date from {{ ref('int_breaks__run_history') }}
),

internal_items as (
    select
        e.event_id,
        e.flow_type,
        e.event_date,
        e.available_from,
        abs(e.signed_amount_cents)                          as amount_cents,
        {{ settlement_window_days('e.flow_type') }} + 3     as maturity_days
    from {{ ref('int_recon_events__unioned') }} e
    where e.side = 'internal'
),

item_match as (
    select
        unnest(m.internal_event_ids)                        as event_id,
        m.match_tier,
        m.matched_on_date,
        m.is_within_tolerance
    from {{ ref('int_matches__all') }} m
),

-- item x run: is it matured, is it matched, as of that run
item_run as (
    select
        s.run_date,
        i.flow_type,
        i.event_id,
        i.amount_cents,
        s.run_date >= i.event_date + interval (i.maturity_days) day          as is_matured,
        m.matched_on_date is not null and m.matched_on_date <= s.run_date   as is_matched,
        coalesce(m.is_within_tolerance, false)                              as is_clean,
        m.match_tier
    from spine s
    join internal_items i on i.available_from <= s.run_date
    left join item_match m on m.event_id = i.event_id
),

volume as (
    select
        run_date,
        flow_type,
        count(*)                                                            as items_visible,
        count(*)                filter (where is_matured)                   as items_matured,
        count(*)                filter (where is_matured and is_matched)    as items_matched,
        count(*)                filter (where is_matured and is_matched and is_clean) as items_clean,
        sum(amount_cents)       filter (where is_matured)                   as value_matured_cents,
        sum(amount_cents)       filter (where is_matured and is_matched)    as value_matched_cents,
        count(*)                filter (where is_matured and is_matched and match_tier = 1) as matched_tier1,
        count(*)                filter (where is_matured and is_matched and match_tier = 2) as matched_tier2,
        count(*)                filter (where is_matured and is_matched and match_tier = 3) as matched_tier3,
        count(*)                filter (where is_matured and is_matched and match_tier = 4) as matched_tier4
    from item_run
    group by all
),

queue as (
    select
        run_date,
        flow_type,
        count(*)            filter (where is_true_break)                    as open_breaks,
        sum(exposure_cents) filter (where is_true_break)                    as unexplained_exposure_cents,
        max(sla_clock_bd)   filter (where is_true_break)                    as oldest_open_break_bd,
        count(*)            filter (where is_true_break and is_sla_breached) as sla_breached,
        count(*)            filter (where is_true_break and severity = 'critical') as open_critical,
        count(*)            filter (where not is_true_break)                as in_transit_items,
        sum(exposure_cents) filter (where not is_true_break)                as in_transit_cents
    from {{ ref('int_breaks__run_history') }}
    group by all
)

select
    v.run_date,
    v.flow_type,
    coalesce(q.unexplained_exposure_cents, 0)                               as unexplained_exposure_cents,
    coalesce(q.open_breaks, 0)                                              as open_breaks,
    coalesce(q.oldest_open_break_bd, 0)                                     as oldest_open_break_bd,
    coalesce(q.sla_breached, 0)                                             as sla_breached,
    coalesce(q.open_critical, 0)                                            as open_critical,
    coalesce(q.in_transit_items, 0)                                         as in_transit_items,
    coalesce(q.in_transit_cents, 0)                                         as in_transit_cents,
    v.items_visible,
    v.items_matured,
    v.items_matched,
    v.items_clean,
    round(v.items_matched  / nullif(v.items_matured, 0), 5)                as match_rate,
    round(v.items_clean    / nullif(v.items_matured, 0), 5)                as clean_match_rate,
    round(v.value_matched_cents / nullif(v.value_matured_cents, 0), 5)     as value_match_rate,
    v.matched_tier1,
    v.matched_tier2,
    v.matched_tier3,
    v.matched_tier4,
    round(v.matched_tier1 / nullif(v.items_matched, 0), 4)                 as tier1_share
from volume v
left join queue q using (run_date, flow_type)
order by v.run_date, v.flow_type
