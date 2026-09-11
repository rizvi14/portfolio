-- Our books: one row per ledger entry, canonicalised.
-- Staging does renames, casts and sign convention only. No joins, no business
-- logic - those belong in intermediate where they can be tested in isolation.

select
    ledger_entry_id,
    txn_id,
    flow_type,
    entry_type,
    account_id,
    counterparty_name,
    {{ normalize_counterparty('counterparty_name') }}    as counterparty_norm,
    counterparty_account_hash,
    direction,
    amount_cents,
    {{ signed_amount('amount_cents', 'direction') }}     as signed_amount_cents,
    currency,
    fx_rate,
    posted_at_utc,
    effective_date,
    gl_account_code,
    {{ normalize_reference('external_ref') }}            as txn_ref,
    {{ reference_suffix('external_ref') }}               as txn_ref_suffix,
    batch_id,
    available_from
from {{ source('raw', 'internal_ledger') }}
