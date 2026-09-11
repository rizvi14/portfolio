-- Card processor settlement file. Clearings only: an authorisation is a memo
-- hold against available balance, not a GL event, so it is out of scope for a
-- money reconciliation and never appears here.

select
    processor_txn_id,
    {{ normalize_reference('arn') }}                        as txn_ref,
    {{ reference_suffix('arn') }}                           as txn_ref_suffix,
    auth_code,
    arn,
    -- Chargeback / representment legs carry CB.. / RP.. ARNs that will never
    -- match an original; keep the signal so classification can pair them.
    arn like 'CB%' or arn like 'RP%'                        as is_dispute_leg,
    auth_amount_cents,
    settled_amount_cents,
    {{ signed_amount('settled_amount_cents', 'direction') }} as signed_amount_cents,
    interchange_fee_cents,
    network_fee_cents,
    currency,
    direction,
    settlement_date,
    merchant_ref                                            as counterparty_name,
    {{ normalize_counterparty('merchant_ref') }}            as counterparty_norm,
    available_from
from {{ source('raw', 'card_settlement') }}
