# RCA-003 — Wires after cutoff, and a clock that could not see weekends

| | |
|---|---|
| **Break code** | `timing_late` raised in error; correct state `in_transit` |
| **Rail** | Wire — but the second root cause affected every rail |
| **Owner** | Reconciliation (this was our defect) |
| **Severity** | False positives; no dollars at risk. Queue credibility at risk. |
| **Items** | 44 wires that rolled to the next business day; 7 of them Friday → Monday |
| **Status** | Both root causes fixed; regression test in place |

## Summary

Wires released after the Fedwire cutoff settle the next business day. On a
same-day rail that is the ordinary behaviour of the rail — nothing has gone
wrong, and the bank's value date says so. The first version of the
reconciliation raised them as late settlements anyway, and the Friday ones
looked three days late on a rail whose window is zero.

Investigating why took the analysis somewhere more useful than wire cutoff:
the business-day clock the whole queue ran on was wrong, in a way that
mis-aged one weekday in five on every rail, and the classic implementation
is wrong in DuckDB while being right in Snowflake.

## How it surfaced

The first scored run of the queue (`agg_matching_rule_performance`) showed
304 false positives — items with `truth_is_true_break = false` raised as
`timing_late`. Breaking them down by injected type, they were all
legitimately slow settlements: card partial refunds, ACH riding the next
file, and wire cutoff rolls. The wire ones were the strangest, because a wire
that settled on the very next business day was being reported as 3 days old.

## Investigation

### Root cause 1 — the clock

`int_breaks__run_history` computed age in business days as

```sql
date_diff('day', event_date, run_date) - 2 * date_diff('week', event_date, run_date)
```

This is the textbook shortcut and it relies on `date_diff('week', ...)`
counting the number of week boundaries crossed. In DuckDB it does not: it
returns the calendar-day difference divided by seven, truncated. For
Friday → Monday that is `3 - 2 * 0 = 3`. The weekend is never subtracted
unless the span is at least seven days long.

Checked directly:

| from | to | calendar | `date_diff('week')` | old formula | correct |
|---|---|---:|---:|---:|---:|
| Fri 2026-03-06 | Mon 2026-03-09 | 3 | 0 | **3** | 1 |
| Fri 2026-03-06 | Tue 2026-03-10 | 4 | 0 | **4** | 2 |
| Fri 2026-03-06 | Fri 2026-03-13 | 7 | 1 | 5 | 5 |

Every item whose transaction date was a Friday — 20% of volume on every
rail — carried two phantom days of age from the following Monday onward.
SLA breaches were inflated the same way, since `days_in_queue_bd` used the
same expression.

Snowflake's `DATEDIFF(week, ...)` counts boundaries and would have returned
1. The same SQL means two different things in the two warehouses, and a
port in either direction would silently change every SLA in the queue with
no error and no failing test. That is the part worth remembering.

### Root cause 2 — the threshold

Even with a correct clock, a wire that rolls over cutoff is one business day
old before its bank record appears, and the policy window for wire is zero.
The original rule was `age <= window + 1 grace day`, which just clears it —
but the same rule on ACH (`1 + 1 = 2`) did not clear an ACH riding the next
file (2–3 days), and on card (`2 + 1 = 3`) did not clear a partial refund's
second leg (3–4 days). The policy window plus a fixed grace was the wrong
shape for a threshold: the rails' real tails differ, and the policy number
does not describe them.

## Remediation

**Clock.** `macros/business_days.sql` indexes each date by weekdays elapsed
since a fixed Monday and subtracts the indexes. Saturday and Sunday take the
following Monday's index, so any span containing a weekend gains nothing
from it. `assert_business_day_clock_is_correct` pins twelve hand-computed
cases including Friday → Monday, Thursday → Monday, month- and year-end
crossings. Bank holidays are not modelled; the macro is the seam where a
holiday calendar would join.

**Threshold.** `int_settlement_profile` measures the arrival-lag
distribution per rail from cleanly matched pairs — no ground truth — and sets
the investigation threshold at the observed p99, floored at the policy window
plus grace and capped by a ceiling so a degrading rail cannot widen its own
definition of on-time. Wire's p99 is 0 and its floor is 1, so the threshold
is 1: a cutoff roll is in transit, and anything that has not arrived by the
second business day is late.

`assert_in_transit_not_flagged_as_break` guards the outcome, anchored on the
**policy** window rather than the calibrated threshold — the first version of
that test used the threshold itself, and passed with the threshold forced to
a value that raised 64,210 normal settlements as breaks. A control that
grades a decision against the knob that made it cannot fail.

## Outcome

| | before | after |
|---|---:|---:|
| false positives (transaction grain) | 304 | 0 |
| precision | 0.9418 | 1.0000 |
| recall | 0.9921 | 0.9909 |

The recall cost is 36 late ACH settlements that sit in a lag band shared
with 515 legitimate in-transit items and cannot be separated by age alone.
That is a real trade and it is made explicitly: on that rail, at that lag,
raising the exception means raising fourteen false alarms for every genuine
one, and the queue would stop being read.

## What would have caught this earlier

A unit test on the date arithmetic, written before the first model used it.
Business-day math is the kind of thing that is obviously right until it is
checked against a calendar, and the check takes twelve rows.

## Related

- RCA-002 for the other first-run scorecard finding (tolerance).
- `docs/snowflake-portability.md` lists this alongside the other places the
  two dialects disagree in ways that do not error.
