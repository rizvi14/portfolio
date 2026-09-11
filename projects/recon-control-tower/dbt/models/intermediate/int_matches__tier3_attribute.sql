-- Tier 3: attribute matching for items with no usable reference.
--
-- Exact amount + same counterparty identity + external date inside the rail's
-- settlement window. The counterparty key is the ACCOUNT HASH where the source
-- provides one and the normalised name only as a fallback - names get
-- rewritten by Notification-of-Change and bank free-text mangling, account
-- identity does not (RCA-004 measures the recall difference).
--
-- The equi-join on (flow, currency, amount, counterparty) is the blocking key:
-- it keeps candidate generation bounded instead of a cross join.
--
-- Where several candidates survive, the pair is kept only if each side is the
-- other's nearest-dated candidate (mutual best), so one external item can
-- never be claimed by two internal items.

with matched_so_far as (
    select unnest(internal_event_ids) as event_id from {{ ref('int_matches__tier1_exact') }}
    union all
    select unnest(external_event_ids) from {{ ref('int_matches__tier1_exact') }}
    union all
    select unnest(internal_event_ids) from {{ ref('int_matches__tier2_aggregate') }}
    union all
    select unnest(external_event_ids) from {{ ref('int_matches__tier2_aggregate') }}
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
        abs(date_diff('day', i.event_date, e.event_date)) as date_gap
    from events i
    join events e
        on  i.side = 'internal' and e.side = 'external'
        and i.flow_type           = e.flow_type
        and i.currency            = e.currency
        and i.signed_amount_cents = e.signed_amount_cents
        and i.counterparty_key    = e.counterparty_key
        and {{ within_settlement_window('i.event_date', 'e.event_date', 'i.flow_type') }}
),

ranked as (
    select
        *,
        row_number() over (partition by internal_event_id order by date_gap, external_event_id) as rank_from_internal,
        row_number() over (partition by external_event_id order by date_gap, internal_event_id) as rank_from_external
    from candidates
)

select
    'T3-' || internal_event_id                  as match_id,
    3                                           as match_tier,
    'attribute_amount_date_cpty'                as match_rule,
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
