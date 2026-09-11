-- Opening exceptions + opened - closed = closing exceptions, every month,
-- every rail.
--
-- A closing count on its own is not evidence of anything: it looks reasonable
-- whatever happened, which is why a queue can lose items - dropped by a filter,
-- stranded under a renamed break code, silently reclassified - without anyone
-- noticing for a quarter. The roll-forward is what makes the population
-- auditable, because it forces this month's opening balance to be last month's
-- closing balance and every difference between them to be a movement someone
-- can name.
--
-- The identity holds by construction given how opened and closed are defined,
-- which is exactly why it is worth asserting: it fails when the construction
-- changes, and the construction is the thing that is easy to change without
-- meaning to.

select
    close_month,
    close_date,
    flow_type,
    opening_breaks,
    opened_breaks,
    closed_breaks,
    open_breaks,
    rollforward_gap
from {{ ref('rpt_close_summary') }}
where rollforward_gap <> 0
