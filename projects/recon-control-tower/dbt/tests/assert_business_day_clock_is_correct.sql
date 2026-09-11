-- The business-day clock, checked against a hand-built calendar.
--
-- This test exists because the obvious implementation is wrong and the wrong
-- answer is plausible: date_diff('day',a,b) - 2*date_diff('week',a,b) returns
-- 3 for Friday -> Monday in DuckDB, because date_diff('week') there is the day
-- difference divided by seven rather than the number of week boundaries
-- crossed. Snowflake's DATEDIFF(week, ...) counts boundaries and gives 1, so
-- the same expression means different things in the two warehouses and a port
-- in either direction silently changes every SLA in the queue.
--
-- Fails if any case disagrees. Weekend dates take the following Monday's
-- index, so a span containing a weekend gains nothing from it.

with cases(start_date, end_date, expected_bd, note) as (
    values
        (DATE '2026-03-02', DATE '2026-03-02',  0, 'same day, Monday'),
        (DATE '2026-03-02', DATE '2026-03-03',  1, 'Mon -> Tue'),
        (DATE '2026-03-02', DATE '2026-03-06',  4, 'Mon -> Fri, same week'),
        (DATE '2026-03-06', DATE '2026-03-09',  1, 'Fri -> Mon, weekend is free'),
        (DATE '2026-03-06', DATE '2026-03-07',  1, 'Fri -> Sat, Sat indexes to Mon'),
        (DATE '2026-03-06', DATE '2026-03-08',  1, 'Fri -> Sun, Sun indexes to Mon'),
        (DATE '2026-03-05', DATE '2026-03-09',  2, 'Thu -> Mon'),
        (DATE '2026-03-02', DATE '2026-03-09',  5, 'Mon -> Mon, one full week'),
        (DATE '2026-03-02', DATE '2026-03-16', 10, 'Mon -> Mon, two full weeks'),
        (DATE '2026-03-06', DATE '2026-03-20', 10, 'Fri -> Fri, two full weeks'),
        (DATE '2026-03-02', DATE '2026-04-01', 22, 'Mon -> Wed, crossing a month'),
        (DATE '2026-12-31', DATE '2027-01-04',  2, 'Thu -> Mon, crossing a year')
)

select
    start_date,
    end_date,
    note,
    expected_bd,
    {{ business_days_between('start_date', 'end_date') }} as actual_bd
from cases
where {{ business_days_between('start_date', 'end_date') }} <> expected_bd
