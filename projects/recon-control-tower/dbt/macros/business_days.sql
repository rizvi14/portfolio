{#
  Business-day arithmetic.

  Every SLA in a reconciliation shop is quoted in business days, and every
  settlement window is a business-day window: a Friday ACH that lands Monday
  is one day old, not three. Getting this wrong does not produce a subtle
  error - it produces an exception queue where one weekday in five looks
  chronically late, which is exactly the kind of false alarm that teaches
  analysts to ignore the queue.

  The obvious shortcut

      date_diff('day', a, b) - 2 * date_diff('week', a, b)

  is WRONG in DuckDB. date_diff('week', a, b) is the day difference divided by
  seven, not the number of week boundaries crossed, so it returns 0 for
  Friday -> Monday and the weekend is never subtracted. Snowflake's
  DATEDIFF(week, ...) counts boundaries and would give the right answer, which
  is what makes this failure so easy to carry across a port in either
  direction. Verified against a hand-built calendar in
  tests/assert_business_day_clock_is_correct.sql.

  Instead, index each date by the number of weekdays elapsed since a fixed
  Monday and subtract the indexes. Saturday and Sunday share the index of the
  following Monday, so a weekend contributes zero days to every span that
  contains it.

  Bank holidays are NOT modelled. A production build would join a calendar
  table (the Federal Reserve holiday schedule for ACH and Fedwire, card
  networks settle every day); the macro is the seam where that join goes.
#}

{% macro weekday_index(d) -%}
    (
        (date_diff('day', DATE '2000-01-03', {{ d }}) // 7) * 5
        + least(date_diff('day', DATE '2000-01-03', {{ d }}) % 7, 5)
    )
{%- endmacro %}

{% macro business_days_between(start_date, end_date) -%}
    ({{ weekday_index(end_date) }} - {{ weekday_index(start_date) }})
{%- endmacro %}
