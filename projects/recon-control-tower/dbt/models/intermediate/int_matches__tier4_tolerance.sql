-- Tier 4: tolerance matching - the last, loosest rule.
--
-- Same counterparty identity, amount within tolerance (absolute floor OR
-- basis-point band, whichever is larger), external date inside the settlement
-- window. Nearest amount wins, then nearest date, and only mutual-best pairs
-- survive.
--
-- This tier exists to absorb small structural differences on items that also
-- lost their reference. It is the tier most tempting to loosen when the queue
-- is long, and the one whose precision the evaluation mart watches most
-- closely: a false match here hides a real loss behind a green number.

with matched_so_far as (
    select unnest(internal_event_ids) as event_id from {{ ref('int_matches__tier1_exact') }}
    union all
    select unnest(external_event_ids) from {{ ref('int_matches__tier1_exact') }}
    union all
    select unnest(internal_event_ids) from {{ ref('int_matches__tier2_aggregate') }}
    union all
    select unnest(external_event_ids) from {{ ref('int_matches__tier2_aggregate') }}
    union all
    select unnest(internal_event_ids) from {{ ref('int_matches__tier3_attribute') }}
    union all
    select unnest(external_event_ids) from {{ ref('int_matches__tier3_attribute') }}
),

events as (
    select e.*
    from {{ ref('int_recon_events__unioned') }} e
    where e.event_id not in (select event_id from matched_so_far)
      and e.counterparty_key is not null
),

candidates as (
    select
        i.event_id                          as internal_event_id,
        e.event_id                          as external_event_id,
        i.flow_type,
        i.currency,
        i.signed_amount_cents               as internal_amount_cents,
        e.signed_amount_cents               as external_amount_cents,
        i.event_date                        as internal_event_date,
        e.event_date                        as external_event_date,
        i.available_from                    as internal_available_from,
        e.available_from                    as external_available_from,
        abs(i.signed_amount_cents - e.signed_amount_cents)  as amount_gap,
        abs(date_diff('day', i.event_date, e.event_date))   as date_gap
    from events i
    join events e
        on  i.side = 'internal' and e.side = 'external'
        and i.flow_type        = e.flow_type
        and i.currency         = e.currency
        and i.counterparty_key = e.counterparty_key
        and sign(i.signed_amount_cents) = sign(e.signed_amount_cents)
        and {{ amount_within_tolerance('i.signed_amount_cents', 'e.signed_amount_cents', 'i.flow_type') }}
        and {{ within_settlement_window('i.event_date', 'e.event_date', 'i.flow_type') }}
),

ranked as (
    select
        *,
        row_number() over (partition by internal_event_id order by amount_gap, date_gap, external_event_id) as rank_from_internal,
        row_number() over (partition by external_event_id order by amount_gap, date_gap, internal_event_id) as rank_from_external
    from candidates
)

select
    'T4-' || internal_event_id                  as match_id,
    4                                           as match_tier,
    'tolerance_window_cpty'                     as match_rule,
    flow_type,
    currency,
    [internal_event_id]                         as internal_event_ids,
    [external_event_id]                         as external_event_ids,
    1                                           as internal_count,
    1                                           as external_count,
    internal_amount_cents,
    external_amount_cents,
    internal_amount_cents - external_amount_cents as variance_cents,
    internal_event_date,
    external_event_date,
    internal_available_from,
    external_available_from,
    external_available_from                     as external_first_available_from,
    greatest(internal_available_from, external_available_from) as matched_on_date
from ranked
where rank_from_internal = 1 and rank_from_external = 1
