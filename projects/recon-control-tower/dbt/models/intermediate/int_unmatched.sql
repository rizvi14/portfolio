-- Everything the waterfall could not pair, on either side.
--
-- These are the ORPHAN candidates. Not all of them are breaks: an internal
-- item whose bank record is still inside the settlement window is simply in
-- transit. Classification decides; this model only isolates the residue.

with match_events as (
    select match_id, unnest(internal_event_ids) as event_id from {{ ref('int_matches__all') }}
    union all
    select match_id, unnest(external_event_ids) from {{ ref('int_matches__all') }}
)

select
    e.*,
    -- Reference cardinality on the SAME side is the duplicate signature:
    -- an orphan whose reference already matched elsewhere on its own side is
    -- a second copy, not a missing counterpart.
    count(*) over (partition by e.side, e.flow_type, e.currency, e.txn_ref)
        as same_side_ref_count
from {{ ref('int_recon_events__unioned') }} e
where e.event_id not in (select event_id from match_events)
