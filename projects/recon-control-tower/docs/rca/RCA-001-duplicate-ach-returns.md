# RCA-001 — ACH returns booked twice

| | |
|---|---|
| **Break code** | `duplicate_internal` (variance family) |
| **Rail** | ACH |
| **Owner** | Engineering |
| **Severity** | High — SLA 1 business day |
| **Items** | 148 returns over 120 days, ~1.2 per business day |
| **Gross exposure** | $4,399,800.46 (the duplicated leg; net cash impact is zero, ledger overstatement is not) |
| **Status** | Root cause confirmed in data; ingestion fix proposed; detection control in place |

## Summary

ACH returns (R01–R29) are being posted to the ledger twice. Both postings carry
the same trace number, the same amount and the same return code, and land
2–6 seconds apart. The bank reports each return exactly once. The ledger's
ACH clearing account is overstated by the duplicated leg until each pair is
corrected.

This is not a bank problem and not a matching problem. It is an ingestion
defect — a retry without an idempotency key — and the reconciliation found it
because the matching engine is allowed to pair one bank record with two ledger
records and then say what it thinks about the ratio.

## How it surfaced

Tier 1 (exact reference, 1:1) refuses any reference that is not unique on
both sides, so these never matched there. They fell through to tier 2
(aggregate by reference), which summed both ledger postings against the single
bank line and linked them as one match with a variance.

`int_breaks__candidates` classifies a tier-2 variance where one side is a
whole multiple of the other:

```sql
when match_rule = 'aggregate_ref' and internal_count > external_count
     and abs(internal_amount_cents) between abs(external_amount_cents) * 1.98
                                        and abs(external_amount_cents) * 2.02
                                                            then 'duplicate_internal'
```

All 148 items landed there. Recall against ground truth is 1.000 with zero
false positives (`agg_matching_rule_performance`, subject
`ach_duplicate_return`).

What made this findable is that the two ledger rows were **kept linked** to
the bank row rather than being raised as two separate orphans. Two orphans
say "something is wrong twice"; one linked pair at exactly 2.0× says "this was
posted twice", and points at ingestion rather than at the bank.

## Investigation

1. **Is the bank double-reporting?** No. For every affected trace, the
   partner statement has exactly one return line. (`stg_partner_bank_statement`,
   grouped by trace and return code.)
2. **Is this a legitimate second return?** No. A re-presented item that returns
   again would carry a later settlement date and, usually, a different return
   reason. These pairs are seconds apart with identical codes.
3. **Is it concentrated?** Return codes are evenly spread (R01/R02/R03/R05/R10/R29
   each 26–35 of the unlinked population), so it is not a code-specific
   handler. It is the return path as a whole.
4. **What is 2–6 seconds?** A retry window. The return-processing consumer
   acknowledges late (or not at all), the message is redelivered, and the
   second delivery is processed as new because nothing on the write path
   checks whether the trace has already been posted.

## Root cause

The ledger's ACH return handler is not idempotent. Message redelivery — a
normal, expected behaviour of the queue — produces a second posting because
the write path keys on an internal event id rather than on the ACH trace
number plus return code that uniquely identifies the return.

## Contributing factors

- The return path was built later than the origination path and did not
  inherit its dedupe-on-trace check.
- No monitoring on "ledger postings per trace" — the first place this would
  have shown up before reconciliation.
- Match rate did not move. Tier 2 linked every one of these, so the headline
  number stayed green while the clearing account drifted. This is the standard
  argument for leading with unexplained exposure rather than match rate
  (`agg_recon_daily` orders its columns accordingly).

## Remediation

**Proposed (Engineering):**

- Idempotency key on the return handler: `(trace_number, return_code, amount,
  settlement_date)`. Reject or no-op the second delivery.
- Backfill: reverse the 148 duplicated legs with a single correcting journal
  per period. Until posted, the balance sits in `awaiting_correction_cents` on
  the ACH tie-out (`fct_gl_tieout`).

**In place (Reconciliation):**

- Detection: the 2.0× aggregate-ratio classifier above. Severity `high`,
  owner Engineering, SLA 1 business day — a duplicate is a system defect, not
  an investigation, and should be routed as one.
- Monitoring: any day with more than three `duplicate_internal` items on a
  single rail should page, because the base rate is ~1.2/day and a retry storm
  would produce dozens in minutes.

## What would have caught this earlier

A count of ledger postings per ACH trace, run daily, alerting on any trace
with more than one. It is a five-line query against the ledger alone — no
bank data needed — and it fires the same day the first duplicate lands, not
on the next reconciliation run.

## Related

- The mirror-image defect on the bank side — a statement file redelivered
  and re-ingested — presents as `duplicate_external` at the same 2.0× ratio
  from the other direction (64 ACH, 337 card, 22 wire items in this period).
  It **raises** the match rate, since every duplicate finds its original.
  Same control, opposite owner (Banking Partner, severity `critical`).
- `assert_no_double_matched_events` is the structural guard that the fix to
  this class of problem is never "let tier 1 match twice".
