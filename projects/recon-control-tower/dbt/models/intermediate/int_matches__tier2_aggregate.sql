-- Tier 2: aggregate matching - many-to-one, one-to-many, many-to-many.
--
-- Two shapes land here:
--   2a  a reference that is NOT unique on one side (a duplicated internal
--       posting, a refund settled in two parts). Both sides are summed by
--       reference and compared. Sums agreeing = clean aggregate match; sums
--       disagreeing = a linked variance, and the ratio of the sums is itself
--       diagnostic (2.0x internal is the duplicate-posting signature in RCA-001).
--   2b  a settlement batch: N reference-less internal entries sharing a batch
--       id against one bank line for the whole batch.
--
-- Only events untouched by tier 1 are eligible.

with tier1_events as (
    select unnest(internal_event_ids) as event_id from {{ ref('int_matches__tier1_exact') }}
    union all
    select unnest(external_event_ids) from {{ ref('int_matches__tier1_exact') }}
),

events as (
    select e.*
    from {{ ref('int_recon_events__unioned') }} e
    where e.event_id not in (select event_id from tier1_events)
),

-- 2a: reference groups
ref_groups as (
    select
        flow_type,
        currency,
        txn_ref                                                   as group_key,
        'aggregate_ref'                                           as match_rule,
        list(event_id) filter (where side = 'internal')           as internal_event_ids,
        list(event_id) filter (where side = 'external')           as external_event_ids,
        count(*) filter (where side = 'internal')                 as internal_count,
        count(*) filter (where side = 'external')                 as external_count,
        sum(signed_amount_cents) filter (where side = 'internal') as internal_amount_cents,
        sum(signed_amount_cents) filter (where side = 'external') as external_amount_cents,
        min(event_date) filter (where side = 'internal')          as internal_event_date,
        min(event_date) filter (where side = 'external')          as external_event_date,
        max(available_from) filter (where side = 'internal')      as internal_available_from,
        max(available_from) filter (where side = 'external')      as external_available_from,
        -- the FIRST external leg. A refund that settles in two parts is
        -- partially settled from this date, which is knowable at run time and
        -- is a different queue state from nothing having arrived at all.
        min(available_from) filter (where side = 'external')      as external_first_available_from
    from events
    where txn_ref is not null and not is_ref_truncated
    group by all
    having internal_count >= 1 and external_count >= 1
),

-- 2b: batch groups, reference-less items only
batch_groups as (
    select
        flow_type,
        currency,
        batch_id                                                  as group_key,
        'aggregate_batch'                                         as match_rule,
        list(event_id) filter (where side = 'internal')           as internal_event_ids,
        list(event_id) filter (where side = 'external')           as external_event_ids,
        count(*) filter (where side = 'internal')                 as internal_count,
        count(*) filter (where side = 'external')                 as external_count,
        sum(signed_amount_cents) filter (where side = 'internal') as internal_amount_cents,
        sum(signed_amount_cents) filter (where side = 'external') as external_amount_cents,
        min(event_date) filter (where side = 'internal')          as internal_event_date,
        min(event_date) filter (where side = 'external')          as external_event_date,
        max(available_from) filter (where side = 'internal')      as internal_available_from,
        max(available_from) filter (where side = 'external')      as external_available_from,
        -- the FIRST external leg. A refund that settles in two parts is
        -- partially settled from this date, which is knowable at run time and
        -- is a different queue state from nothing having arrived at all.
        min(available_from) filter (where side = 'external')      as external_first_available_from
    from events
    where txn_ref is null and batch_id is not null
    group by all
    having internal_count >= 1 and external_count >= 1
),

unioned as (
    select * from ref_groups
    union all
    select * from batch_groups
)

select
    'T2-' || group_key                          as match_id,
    2                                           as match_tier,
    match_rule,
    flow_type,
    currency,
    internal_event_ids,
    external_event_ids,
    internal_count,
    external_count,
    internal_amount_cents,
    external_amount_cents,
    internal_amount_cents - external_amount_cents as variance_cents,
    internal_event_date,
    external_event_date,
    internal_available_from,
    external_available_from,
    external_first_available_from,
    greatest(internal_available_from, external_available_from) as matched_on_date
from unioned
