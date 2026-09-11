# Matching rules — technical specification

How two records become one match, in the order the rules run, and what each
rule is and is not allowed to do. This is the document an engineer would
build from and an auditor would test against.

## Inputs

Every source is mapped to one shape before any rule runs
(`int_recon_events__unioned`). A rule never sees a ledger column or a bank
column; it sees the contract:

| column | meaning | rules that use it |
|---|---|---|
| `event_id` | unique within side | all |
| `side` | `internal` / `external` | all |
| `flow_type` | `ach` / `card` / `wire` | all — no rule crosses rails |
| `currency` | ISO code | all — no rule crosses currencies |
| `txn_ref` | normalised shared reference (ACH trace, wire IMAD, card ARN); null if absent | T1, T2a |
| `txn_ref_suffix` | last 12 characters of the reference | T1b |
| `is_ref_truncated` | the reference was cut by the source | T1 (excludes), T1b (includes) |
| `signed_amount_cents` | integer minor units, +in / −out | T2, T3, T4 |
| `event_date` | the date the system says it happened | T3, T4 |
| `available_from` | the date recon could first see it | queue, not matching |
| `counterparty_key` | account hash where the source has one; normalised name otherwise | T3, T4 |
| `batch_id` | settlement batch | T2b |

Amounts are integers. A rule that compares floats is a defect.

## The waterfall

Rules run in order. Each tier consumes only events that no earlier tier has
matched (`anti-join on event_id`), so a record can be matched by at most one
rule. `assert_no_double_matched_events` enforces this after the fact;
`assert_matched_plus_unmatched_equals_total` enforces that nothing falls
through the floor.

The order is by **trust**: the most specific rule first, the loosest last, so
that a loose rule never steals a pair the exact rule would have made.

### Tier 1 — exact reference, one-to-one

**Key:** `(flow_type, currency, txn_ref)`
**Condition:** the reference appears **exactly once on each side**.
**Amount:** not consulted. A tier-1 pair with disagreeing amounts is a
*linked variance*, not a non-match — the link is what makes the root cause
findable.

A reference that is not unique on a side is left for tier 2, deliberately. A
1:1 join on a non-unique key either double-matches or picks arbitrarily, and
both corrupt the match rate silently.

**1b — suffix recovery.** Some banks truncate the OBI/reference field in
free text. For events flagged `is_ref_truncated`, join on `txn_ref_suffix`,
again only where the suffix is unique on both sides. 46 wires in this
dataset; all recovered; zero false pairs.

### Tier 2 — aggregate

Many-to-one, one-to-many, many-to-many, where a shared key groups records
whose **sums** should agree.

**2a — by reference.** `(flow_type, currency, txn_ref)` where the reference
is non-unique on at least one side. Sum each side; the pair is the two
groups. Ratio of the sums is diagnostic and feeds classification: internal
≈ 2.0× external is a duplicate posting (RCA-001); external ≈ 2.0× internal
is a redelivered statement file.

**2b — by batch.** Reference-less internal entries sharing a `batch_id`
against a single bank line for the batch. `(flow_type, currency, batch_id)`.

Both require at least one record on each side of the group.

### Tier 3 — attribute

For records with no usable reference at all.

**Blocking key:** `(flow_type, currency, signed_amount_cents, counterparty_key)`
— an equi-join, so candidate generation is bounded rather than a cross join.
**Window:** external `event_date` within the rail's settlement window of the
internal date (`within_settlement_window`).
**Selection:** where several candidates survive, keep a pair only if each
side is the other's nearest-dated candidate (**mutual best**). One external
record can never be claimed by two internal records.

`counterparty_key` is the account hash on every rail that provides one and
the normalised name only where none exists (card). RCA-004 measures why:
under Notification of Change, account identity recovers 114/114 and name
identity 32/114.

### Tier 4 — tolerance

The loosest rule and the one the evaluation mart watches hardest.

**Blocking key:** `(flow_type, currency, counterparty_key, sign(amount))`
**Amount:** `amount_within_tolerance(internal, external, flow_type)` — see
below.
**Window:** as tier 3.
**Selection:** nearest amount, then nearest date, mutual best.

Match-grain precision on tier 4 is reported separately with the dollars a
false pair would have hidden. In this dataset tier 4 makes no matches at
all, which is the correct outcome: everything it could pair was already
paired by a stricter rule. A tier 4 that is busy is a tier 1–3 that is
failing.

## Tolerance

```
|a − b|  ≤  max( tolerance_abs_cents,  |a| × tolerance_bps(flow) / 10 000 )
```

| var | value | absorbs |
|---|---:|---|
| `tolerance_abs_cents` | 50 | FX rounding, sub-dollar fee noise |
| `tolerance_bps_ach` | 25 | nothing structural on the rail; generous |
| `tolerance_bps_card` | 25 | must stay well under interchange (180–220 bps) |
| `tolerance_bps_wire` | **0** | fixed fees are reconciling items, never noise |

Tolerance exists for known, small, structural differences. It is never
widened to absorb a variance that has not been explained. RCA-002 has the
sensitivity table for what 250 bps was hiding.

## What a match is not

A **match** means the waterfall paired the records. It does not mean the
amounts agree. `is_within_tolerance` is judged after pairing, and a pair
outside tolerance is a *variance* exception that stays linked.
`match_rate` counts pairs; `clean_match_rate` counts pairs within tolerance.
Both are reported, side by side, and the control floor is on the first.

## Settlement windows

| rail | policy (business days) | grace | what actually sets the threshold |
|---|---:|---:|---|
| ACH | 1 | 1 | observed p99 arrival lag, floored at policy + grace, capped at `investigation_threshold_ceiling_bd` (6) |
| card | 2 | 1 | as above |
| wire | 0 | 1 | as above |

`int_settlement_profile` calibrates the threshold from cleanly matched pairs
— no ground truth involved — and publishes the p50/p95/p99 so that the
"percentile must sit above the defect rate" assumption is re-checkable.

Business-day arithmetic uses the weekday-index macro in
`macros/business_days.sql`, not `date_diff('week')`. RCA-003.

## Adding a rail

1. One staging model that maps the source into the contract above.
2. One `union all` branch in `int_recon_events__unioned`.
3. Three vars: `window_days_<rail>`, `tolerance_bps_<rail>`, and a branch in
   `settlement_window_days` / `tolerance_bps_for`.
4. Seed rows in `seed_break_taxonomy` for any rail-specific break codes.

No matching tier changes. That is the test of whether the contract is real.

## Adding a rule

A new rule goes in the waterfall at the position its trust level warrants,
anti-joins everything above it, and is graded in
`agg_matching_rule_performance` at the match grain before it is trusted.
Shadow mode — run it, report its pairs, do not consume them — is one
`where false` away and is the recommended first deployment.
