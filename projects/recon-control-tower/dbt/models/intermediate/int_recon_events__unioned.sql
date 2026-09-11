-- The canonical recon-item contract.
--
-- Every system of record is mapped into ONE shape here, and every downstream
-- matching tier consumes only this shape. That is what "standards other
-- analysts build against" looks like in practice: onboarding a fourth funds
-- flow means writing one staging model and one mapping into this contract -
-- not a new matching pipeline.
--
-- Columns every side must supply:
--   event_id               unique within side
--   side                   'internal' | 'external'
--   source_system          which system of record
--   flow_type              ach | card | wire
--   txn_ref                normalised shared reference (may be null)
--   txn_ref_suffix         tail of the reference, for truncation recovery
--   signed_amount_cents    +in / -out, integer minor units
--   currency
--   event_date             the date the system says it happened
--   available_from         the date the record became visible to recon
--   counterparty_key       stable identity: account hash where the source
--                          provides one, normalised name otherwise
--   batch_id               settlement batch, for aggregate matching
--   hint_*                 side-specific signals used only by classification

with internal as (
    select
        ledger_entry_id                         as event_id,
        'internal'                              as side,
        'ledger'                                as source_system,
        flow_type,
        txn_ref,
        txn_ref_suffix,
        false                                   as is_ref_truncated,
        signed_amount_cents,
        currency,
        effective_date                          as event_date,
        available_from,
        counterparty_account_hash               as counterparty_key,
        counterparty_norm,
        batch_id,
        gl_account_code,
        entry_type                              as hint_entry_type,
        null::varchar                           as hint_return_code,
        null::varchar                           as hint_bai_code,
        false                                   as hint_is_dispute_leg,
        false                                   as hint_is_redelivered,
        posted_at_utc
    from {{ ref('stg_internal_ledger') }}
),

bank as (
    select
        bank_txn_id                             as event_id,
        'external'                              as side,
        'partner_bank'                          as source_system,
        flow_type,
        txn_ref,
        txn_ref_suffix,
        is_ref_truncated,
        amount_signed_cents                     as signed_amount_cents,
        currency,
        value_date                              as event_date,
        available_from,
        counterparty_account_hash               as counterparty_key,
        counterparty_norm,
        batch_id,
        null::varchar                           as gl_account_code,
        null::varchar                           as hint_entry_type,
        return_code                             as hint_return_code,
        bai_code                                as hint_bai_code,
        false                                   as hint_is_dispute_leg,
        is_redelivered                          as hint_is_redelivered,
        null::timestamp                         as posted_at_utc
    from {{ ref('stg_partner_bank_statement') }}
),

card as (
    select
        processor_txn_id                        as event_id,
        'external'                              as side,
        'card_processor'                        as source_system,
        'card'                                  as flow_type,
        txn_ref,
        txn_ref_suffix,
        false                                   as is_ref_truncated,
        signed_amount_cents,
        currency,
        settlement_date                         as event_date,
        available_from,
        -- The processor exposes only a merchant descriptor, so the normalised
        -- name is the best identity key available on this rail.
        counterparty_norm                       as counterparty_key,
        counterparty_norm,
        null::varchar                           as batch_id,
        null::varchar                           as gl_account_code,
        null::varchar                           as hint_entry_type,
        null::varchar                           as hint_return_code,
        null::varchar                           as hint_bai_code,
        is_dispute_leg                          as hint_is_dispute_leg,
        false                                   as hint_is_redelivered,
        null::timestamp                         as posted_at_utc
    from {{ ref('stg_card_processor_settlement') }}
)

select * from internal
union all
select * from bank
union all
select * from card
