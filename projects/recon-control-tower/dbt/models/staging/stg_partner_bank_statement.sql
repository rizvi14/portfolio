-- Partner-bank statement lines for ACH and wire.
-- The reference lives inside a free-text description, so it is extracted
-- here with regex. Three shapes appear in the wild and all are handled:
--   ACH  ... TRACE#123456789012345 ...
--   WIRE ... IMAD20260302B1Q1234567 ...
--   WIRE ... OBI/.../Q1234567 TRUNCATED BY BANK   (suffix only survives)

with src as (
    select * from {{ source('raw', 'bank_statement_lines') }}
),

extracted as (
    select
        *,
        -- regexp_extract returns '' rather than NULL on a miss, so every
        -- branch is wrapped in nullif or coalesce would short-circuit on the
        -- first empty string.
        coalesce(
            nullif(regexp_extract(description, 'TRACE#([0-9]{15})', 1), ''),
            nullif(regexp_extract(description, '(IMAD[0-9]{8}B1Q[0-9]{7})', 1), ''),
            nullif(regexp_extract(description, 'OBI/\.\.\./([A-Z0-9]+)', 1), '')
        )                                                           as raw_ref,
        coalesce(
            nullif(regexp_extract(description, 'CO=([A-Z0-9 .]+?)(?: NO TRACE| TRUNC|$)', 1), ''),
            nullif(regexp_extract(description, ' REF ([A-Z0-9 .]+?)(?: LIFTING FEE|$)', 1), '')
        )                                                           as raw_counterparty,
        regexp_extract(description, '^ACH RETURN (R[0-9]{2})', 1)   as return_code
    from src
)

select
    bank_txn_id,
    file_id,
    statement_date,
    value_date,
    amount_signed_cents,
    currency,
    description,
    case
        when description like 'FEDWIRE%' then 'wire'
        else 'ach'
    end                                                     as flow_type,
    {{ normalize_reference('raw_ref') }}                    as txn_ref,
    {{ reference_suffix('raw_ref') }}                       as txn_ref_suffix,
    -- A truncated OBI keeps only the tail; flag it so tier 1 does not try an
    -- exact join it can never win.
    description like '%TRUNCATED BY BANK%'                  as is_ref_truncated,
    nullif(raw_counterparty, '')                            as counterparty_name,
    {{ normalize_counterparty('raw_counterparty') }}        as counterparty_norm,
    counterparty_account_hash,
    nullif(return_code, '')                                 as return_code,
    bai_code,
    batch_id,
    available_from,
    is_redelivered
from extracted
