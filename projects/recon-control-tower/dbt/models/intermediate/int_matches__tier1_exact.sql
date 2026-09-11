-- Tier 1: exact reference, strictly one-to-one.
--
-- The genuinely shared key per rail (ACH trace, wire IMAD, card ARN) where it
-- is unique on BOTH sides. Anything with a duplicated reference is deliberately
-- left for tier 2 - a 1:1 join on a non-unique key would either double-match
-- or pick arbitrarily, and both silently corrupt the match rate.
--
-- 1b recovers references a bank truncated in free text by joining on the
-- surviving suffix, again only where that suffix is unique on both sides.

with events as (
    select * from {{ ref('int_recon_events__unioned') }}
    where txn_ref is not null
),

ref_cardinality as (
    select flow_type, currency, txn_ref, side, count(*) as n
    from events
    where not is_ref_truncated
    group by all
),

unique_refs as (
    -- references that appear exactly once on each side
    select flow_type, currency, txn_ref
    from ref_cardinality
    group by all
    having count(*) = 2 and max(n) = 1
),

tier1a as (
    select
        i.flow_type,
        i.currency,
        'exact_ref'                     as match_rule,
        i.event_id                      as internal_event_id,
        e.event_id                      as external_event_id,
        i.signed_amount_cents           as internal_amount_cents,
        e.signed_amount_cents           as external_amount_cents,
        i.event_date                    as internal_event_date,
        e.event_date                    as external_event_date,
        i.available_from                as internal_available_from,
        e.available_from                as external_available_from
    from events i
    join events e
        on  i.flow_type = e.flow_type
        and i.currency  = e.currency
        and i.txn_ref   = e.txn_ref
        and i.side = 'internal' and e.side = 'external'
        and not e.is_ref_truncated
    join unique_refs u
        on  u.flow_type = i.flow_type
        and u.currency  = i.currency
        and u.txn_ref   = i.txn_ref
),

-- 1b: suffix recovery for truncated external references
suffix_cardinality as (
    select flow_type, currency, txn_ref_suffix, side, count(*) as n
    from events
    where txn_ref_suffix is not null
    group by all
),

unique_suffixes as (
    select flow_type, currency, txn_ref_suffix
    from suffix_cardinality
    group by all
    having count(*) = 2 and max(n) = 1
),

tier1b as (
    select
        i.flow_type,
        i.currency,
        'exact_ref_suffix'              as match_rule,
        i.event_id                      as internal_event_id,
        e.event_id                      as external_event_id,
        i.signed_amount_cents           as internal_amount_cents,
        e.signed_amount_cents           as external_amount_cents,
        i.event_date                    as internal_event_date,
        e.event_date                    as external_event_date,
        i.available_from                as internal_available_from,
        e.available_from                as external_available_from
    from events i
    join events e
        on  i.flow_type      = e.flow_type
        and i.currency       = e.currency
        and i.txn_ref_suffix = e.txn_ref_suffix
        and i.side = 'internal' and e.side = 'external'
        and e.is_ref_truncated
    join unique_suffixes u
        on  u.flow_type      = i.flow_type
        and u.currency       = i.currency
        and u.txn_ref_suffix = i.txn_ref_suffix
),

unioned as (
    select * from tier1a
    union all
    select * from tier1b
)

select
    'T1-' || internal_event_id                  as match_id,
    1                                           as match_tier,
    match_rule,
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
from unioned
