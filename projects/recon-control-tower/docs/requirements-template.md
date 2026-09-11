# Reconciliation requirements — template

The document to fill in before building a new reconciliation, or before
onboarding a new funds flow into this one. Every section has a reason to
exist; a blank section is a decision nobody has made yet.

The recon-control-tower ACH reconciliation is filled in as the worked example
in the right-hand column.

---

## 1. What is being reconciled

| question | example (ACH) |
|---|---|
| **Internal system of record** | ledger — accounts 1020 (cash in transit, ACH) and 1050 (ACH clearing, outbound) |
| **External system of record** | partner bank statement (BAI2 export) |
| **Grain of the match** | one ledger entry ↔ one bank line, except batches (many ↔ one) and returns (one ↔ one, linked to original) |
| **Population** | every posting to 1020/1050 with `flow_type = ach`; every bank line with a BAI code in the ACH range |
| **What is explicitly out of scope** | card and wire (own recons); intra-company transfers (separate control) |

## 2. Identity — how do we know two records are the same thing

| question | example |
|---|---|
| **Shared key** | ACH trace number (15 digits), present on both sides when the originator populates it |
| **Where it can go missing** | bank free-text truncation; returns referencing the original under a different trace |
| **Fallback identity** | receiver account hash + amount + date |
| **Attributes that are NOT identity** | counterparty name (rewritten under NOC — RCA-004) |

## 3. Timing — when should the two sides agree

| question | example |
|---|---|
| **Contractual settlement window** | T+1 business day |
| **Observed window** | p99 T+3 (`int_settlement_profile`); tail over contract +2 bd |
| **Business-day calendar** | weekends excluded; Federal Reserve holidays *not yet* modelled |
| **Cutoff behaviour** | after 16:00 ET rolls to next business day |
| **Who is told when the observed window drifts** | Banking Partner relationship owner |

## 4. Amounts — what differences are acceptable

| question | example |
|---|---|
| **Absolute tolerance** | 50 cents |
| **Relative tolerance** | 25 bps |
| **What the tolerance is FOR** | rounding only — there are no percentage-shaped fees on the rail |
| **What it must NOT absorb** | anything (RCA-002 for why this question is asked) |
| **Currency** | USD only; no FX |

## 5. Known structural differences

Things that will always produce a difference and are not defects. Each one
needs a break code, an owner and a GL treatment, or it will be raised as an
exception forever.

| difference | break code | owner | GL |
|---|---|---|---|
| bank fees and interest posted on the statement | `bank_adjustment` | Finance | fees / interest income |
| returns arriving without a linkable original | `return_unlinked` | Product | returns payable |
| batched outbound files settled as one bank line | matched by `batch_id`, no break | — | — |

## 6. Exception handling

| question | example |
|---|---|
| **Taxonomy** | `docs/break-taxonomy.md` |
| **Severity and SLA** | `docs/severity-and-sla.md` |
| **When the SLA clock starts** | when actionable — after the settlement window for internal orphans |
| **Routing** | owner column on every queue row |
| **Resolution system** | case management (out of scope here; simulated) |
| **Correcting entries** | posted by Accounting; tracked as `awaiting_correction_cents` until they are |

## 7. Controls

What must be true for the reconciliation to be trusted, and what checks it.

| control | test |
|---|---|
| every record is matched or unmatched, never both, never neither | `assert_matched_plus_unmatched_equals_total`, `assert_no_double_matched_events` |
| every exception has an owner | `assert_break_types_exhaustive` |
| the match rate holds its floor, per rail, on matured items | `assert_match_rate_above_floor` |
| the bank reconciliation foots | `assert_gl_tieout_within_threshold` |
| the exception population rolls forward | `assert_close_rollforward_foots` |
| normal settlements are not raised as breaks | `assert_in_transit_not_flagged_as_break` |
| the SLA flag follows from the clock | `assert_sla_flag_consistent` |
| the business-day clock is a business-day clock | `assert_business_day_clock_is_correct` |
| the matcher is measured, not asserted | `agg_matching_rule_performance` + `check_no_ground_truth_leakage.py` |

## 8. Reporting

| audience | needs | where |
|---|---|---|
| recon analyst, daily | the queue, sorted by exposure then age | `fct_recon_breaks` |
| recon lead, daily | exposure, oldest break, match rate, tier composition | `agg_recon_daily` |
| Accounting, monthly | the tie-out, uncorrected balance, roll-forward | `rpt_close_summary` |
| Banking Partner, monthly | observed settlement vs. contract | `int_settlement_profile` |
| whoever owns the rules | precision / recall per rule | `agg_matching_rule_performance` |

## 9. Open questions

Things that were not decided when this was written. Dated, with an owner.

| question | owner | opened |
|---|---|---|
| Should NOCs update the ledger's counterparty record automatically? | Product | 2026-09 |
| Fed holiday calendar — source and refresh cadence | Reconciliation | 2026-09 |
| Interchange: book at settlement per transaction, or keep the monthly lump? | Accounting | 2026-09 |

---

## Filling this in for a new rail

Sections 1–5 are the conversation with the rail's owner and the banking
partner, and should be done before a line of SQL. Sections 6–8 are mostly
inherited from the existing reconciliation and need only the rail-specific
rows. Section 9 is where honesty goes.
