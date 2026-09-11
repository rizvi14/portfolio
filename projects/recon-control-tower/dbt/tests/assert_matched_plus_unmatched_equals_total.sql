-- Every event is accounted for exactly once: matched or unmatched, never both,
-- never neither.
--
-- This is the completeness control. A reconciliation that silently drops rows
-- - a join that filters instead of preserving, a null counterparty excluded by
-- an inner join - reports a beautiful match rate over a shrinking denominator.
-- Items that fall out of the population stop being anyone's problem, which is
-- the worst possible failure mode for a control function: nobody sees it.
--
-- Fails if the arithmetic does not close, per side and flow so the gap is
-- immediately attributable.

with total as (
    select side, flow_type, count(*) as n_total
    from {{ ref('int_recon_events__unioned') }}
    group by all
),

matched as (
    select side, flow_type, count(distinct event_id) as n_matched
    from (
        select unnest(internal_event_ids) as event_id from {{ ref('int_matches__all') }}
        union all
        select unnest(external_event_ids) from {{ ref('int_matches__all') }}
    ) m
    join {{ ref('int_recon_events__unioned') }} e using (event_id)
    group by all
),

unmatched as (
    select side, flow_type, count(*) as n_unmatched
    from {{ ref('int_unmatched') }}
    group by all
)

select
    t.side,
    t.flow_type,
    t.n_total,
    coalesce(m.n_matched, 0)                                as n_matched,
    coalesce(u.n_unmatched, 0)                              as n_unmatched,
    t.n_total - coalesce(m.n_matched, 0) - coalesce(u.n_unmatched, 0) as gap
from total t
left join matched m using (side, flow_type)
left join unmatched u using (side, flow_type)
where t.n_total <> coalesce(m.n_matched, 0) + coalesce(u.n_unmatched, 0)
