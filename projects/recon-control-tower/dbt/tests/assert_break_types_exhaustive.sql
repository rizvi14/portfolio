-- Every break code the engine emits must exist in the taxonomy.
--
-- The taxonomy is not documentation - it carries the owner, the SLA and the
-- GL treatment. A code that is not in it produces an exception with no owner,
-- no due date and no accounting answer: an item that ages in the queue while
-- everyone assumes someone else has it. In practice this fires when a new
-- classification branch is added to int_breaks__candidates and the seed is
-- not updated in the same change, which is exactly when you want to be
-- stopped.
--
-- Fails with the orphaned code and how many items are stranded under it.

with emitted as (
    select break_code, count(*) as n_items, min(run_date) as first_seen
    from {{ ref('int_breaks__run_history') }}
    group by all
)

select
    e.break_code,
    e.n_items,
    e.first_seen
from emitted e
left join {{ ref('seed_break_taxonomy') }} t on t.break_code = e.break_code
where t.break_code is null
   or e.break_code is null
