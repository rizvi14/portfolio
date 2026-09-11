select
    rate_date,
    currency,
    usd_per_unit
from {{ source('raw', 'fx_rates') }}
