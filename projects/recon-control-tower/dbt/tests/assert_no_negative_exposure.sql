-- Exposure is a magnitude and must never be negative.
--
-- Exposure answers "how many dollars are unexplained". It is an absolute
-- value by construction, and it gets summed across a queue that contains both
-- debits and credits. A single negative leaking in nets against the rest and
-- reports LESS exposure than is really open - the direction that gets a
-- reconciliation signed off when it should not be. Cheap to check, expensive
-- to miss.

select
    break_id,
    run_date,
    break_code,
    flow_type,
    exposure_cents,
    variance_cents
from {{ ref('int_breaks__run_history') }}
where exposure_cents < 0
   or exposure_cents is null
