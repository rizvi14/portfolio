# Severity and SLA

Who gets told, how fast, and when the clock starts.

## Severity

Two inputs: the break code's default (see the taxonomy) and the dollars on
the item. Exposure escalates; it never de-escalates.

| severity | exposure floor | escalation | SLA (bd) |
|---|---:|---|---:|
| **critical** | ≥ $25,000 | Head of Reconciliation + Engineering on-call | 1 |
| **high** | ≥ $5,000 | Reconciliation lead | 2 |
| **medium** | ≥ $500 | owning team's queue | 3 |
| **low** | — | weekly review | 5 |
| none | — | reconciling item; no action | — |

Source: `seed_severity_matrix`. The floors are policy and belong to whoever
owns the control; the mechanism (`int_breaks__candidates` § severity) does
not change when they do.

Some codes are critical regardless of amount. `duplicate_external` is the
example: a redelivered statement file is a data-integrity event, it *raises*
the match rate while it corrupts it, and its dollar figure is irrelevant to
how fast it needs to be found.

## The SLA clock

The SLA clock starts when an item becomes **actionable**, not when the
transaction happened.

An internal ACH orphan is not work anyone can do until the settlement window
has elapsed — before that, the most likely explanation is that the bank
record has not arrived, and paging Engineering to investigate it is how
Engineering learns to ignore pages. So:

```
sla_clock_bd = max(0, business days since it entered the queue
                      − investigation threshold, if the item is age-dependent)
is_sla_breached = is_true_break and sla_clock_bd > sla_business_days
```

Variances and external orphans are actionable on arrival; their threshold
term is zero.

Three clocks exist on every queue row and they are not interchangeable:

| column | measures | used for |
|---|---|---|
| `age_business_days` | since the transaction | classification (in transit vs. late) |
| `days_in_queue_bd` | since the item became visible to recon | aging buckets, reporting |
| `sla_clock_bd` | since the item became actionable | SLA breach, escalation |

All three are business-day clocks; see `macros/business_days.sql` and
RCA-003 for why that was harder than it sounds.

## Aging buckets

`0–1d`, `2–3d`, `4–7d`, `8–30d`, `30d+` on `sla_clock_bd`. The `30d+`
bucket is where losses live; `agg_break_aging` breaks it out by rail,
severity and owner so that "the queue is stable" cannot hide "the old part
of the queue is growing".

## Routing

| owner | receives | why them |
|---|---|---|
| Engineering | duplicates, transpositions, missing external | the platform did something it should not have |
| Finance | missing internal, bank adjustments, fee variances | the books need an entry |
| Product | unlinked returns, chargebacks, auth/capture drift | the customer-facing flow produced an ambiguous record |
| Banking Partner | late settlements, redelivered files | the partner did something it should not have |

Owner is a column on every row, so the queue can be filtered to one team's
work without anyone re-deriving the routing.

## What is deliberately not here

- No auto-resolution. The engine finds; a person closes. Resolution in this
  build is simulated (see `int_breaks__candidates` § resolution) and stated
  as such.
- No paging integration. The thresholds are in `dbt_project.yml` and the
  control runner prints them; wiring them to an alerting system is a
  deployment decision.
- No holiday calendar. The business-day macro is the seam where one goes.
