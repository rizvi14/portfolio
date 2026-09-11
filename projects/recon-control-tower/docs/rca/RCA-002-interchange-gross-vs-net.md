# RCA-002 — Card settlements short by interchange; and what tolerance was hiding

| | |
|---|---|
| **Break code** | `fee_interchange` (variance family) — with a second finding on `fee_lifting` (wire) |
| **Rail** | Card; wire for the second finding |
| **Owner** | Finance |
| **Severity** | Medium — SLA 3 business days |
| **Items** | 1,490 card settlements over 120 days, ~12 per business day |
| **Net variance** | $30,507.24 short of ledger; median ticket $1,044.32; variance 1.80–2.22% of gross |
| **Status** | Root cause is an accounting design decision, not a processor error. Booking change proposed. Tolerance policy rewritten per rail. |

## Summary

Roughly one card settlement in fifty arrives from the processor short of the
amount the ledger booked, by 1.8–2.2% of the transaction. The processor is
not wrong. It remits **net of interchange**, as its contract says it will. The
ledger books **gross**, and nothing posts the interchange expense at
settlement. Every one of these is a real difference between the books and the
bank, and every one of them was invisible under the tolerance policy the
reconciliation started with.

The second half of this document is about that: how a tolerance band chosen
to absorb rounding noise was quietly absorbing a fee, and how the same
mistake in the other direction was hiding correspondent lifting fees on wires
entirely.

## Finding 1 — interchange

### How it surfaced

These pair cleanly at tier 1 (the ARN is intact on both sides), so the match
rate is unaffected. What moves is `clean_match_rate` — matched *and* within
tolerance — which runs 3–4 points below `match_rate` on card
(`agg_recon_daily`, latest run: 0.988 vs 0.953). That gap is the interchange.

`int_breaks__candidates` names the variance by its shape:

```sql
when flow_type = 'card'
     and variance_cents * sign(internal_amount_cents) > 0        -- settled SHORT of booked
     and abs(variance_cents) / abs(internal_amount_cents) between 0.015 and 0.045
                                                            then 'fee_interchange'
```

Recall 0.998 (1,487 of 1,490). The three misses are sub-$3 transactions
where the interchange is under the 50-cent absolute floor — correctly
tolerated, and the floor exists precisely so that a three-cent difference is
not an exception.

### Root cause

The revenue-recognition design books the gross transaction amount to card
clearing at authorisation-capture time. The processor's settlement file
carries the net remittance. The interchange expense is booked monthly from
the processor's statement — as a lump, to an expense account, with no link to
the underlying transactions. So at the transaction grain the ledger is always
1.8–2.2% high against the settlement file, permanently, by policy.

This is a **booking design defect**, not a break. The reconciliation cannot
fix it, but it can stop pretending it is not there.

### Remediation

**Proposed (Finance / Accounting):**

- Book interchange at settlement, per transaction, from the processor file:
  debit interchange expense, credit card clearing, for the difference. The
  settlement file already carries the fee; the ledger simply does not read
  it.
- Until that posts, the difference is a permanent reconciling item and
  belongs on the tie-out as one line, not as 1,490 exceptions. It is reported
  that way in `fct_gl_tieout.variance_over_tolerance_cents`.

**In place (Reconciliation):**

- Classification by shape (settled short, 1.5–4.5%) so that the queue says
  "interchange" rather than "unexplained variance". Owner Finance, medium
  severity — the item is known and the fix is accounting, not investigation.

## Finding 2 — the tolerance was doing accounting's job

The first tolerance policy was a flat **250 basis points** on every rail,
with a 50-cent floor. The reasoning was ordinary: absorb FX rounding, absorb
sub-dollar fee noise, keep the queue readable.

Then the evaluation mart was built, and the scorecard for the first run
showed `wire_fee_deducted` — correspondent lifting fees, $15 to $35 deducted
in transit — at **recall 0.000**. Fifty of fifty injected, none raised.

A 250 bps band on a median $401,559 wire is a $1,004 allowance. A $35 lifting
fee does not register. The tolerance had been set by thinking about
percentages and the fees are fixed amounts, so on a large-ticket rail the
band was three orders of magnitude wider than the thing it was meant to
tolerate.

Same policy, run against interchange:

| tolerance (bps) | interchange variances hidden (of 1,486) | dollars hidden |
|---:|---:|---:|
| 25 | 0 | $0 |
| 50 | 0 | $0 |
| 100 | 0 | $0 |
| 150 | 0 | $0 |
| 200 | 1,477 | $30,500.61 |
| **250** | **1,486** | **$30,507.24** |

At the original setting, the entire interchange finding above does not exist.
`clean_match_rate` equals `match_rate`, the queue is empty of these, and the
card clearing account drifts 1.8% of gross volume per period with nothing on
any report to say so.

### Root cause

Tolerance was set as a single global number and reasoned about as "how much
noise is acceptable". The right question is **"what specifically is this
band absorbing, and is that thing supposed to be invisible?"** The answer
differs by rail:

- **Wire** — the only legitimate differences are FX rounding (cents) and
  nothing else. Every fixed fee is a reconciling item that Finance needs to
  see and reclass. `tolerance_bps_wire: 0`; the 50-cent floor covers
  rounding.
- **Card** — interchange is 180–220 bps and is *not* noise; it is an
  accounting policy gap. Anything at or above 200 bps hides it.
  `tolerance_bps_card: 25`.
- **ACH** — no percentage-shaped fees on the rail at all; 25 bps is generous.

### Remediation

- `dbt_project.yml` now carries tolerance **per rail**, with the reasoning in
  the comment block, and `amount_within_tolerance` takes the flow as an
  argument. Wire recall on lifting fees went from 0.000 to 1.000 with no
  other change.
- `fct_gl_tieout` carries `tolerated_variance_cents` as an explicit bridge
  line. Differences the policy chooses not to raise do not vanish; they
  accumulate in the clearing account, and the tie-out now shows that
  accumulation instead of folding it into "matched". In this dataset it is
  cents. With real FX it would not be, and the line is where the cost of
  every basis point of tolerance becomes a number.

## What would have caught this earlier

The scorecard did. This is the argument for building the evaluation mart
before tuning a single rule: a recall of 0.000 on a break type is not a
statistic, it is a bug report with the rule's name on it. Without injected
ground truth, the equivalent is a periodic back-test — take last quarter's
resolved breaks, replay them through the current rules, and see which ones
the rules would no longer raise.

## Related

- `agg_matching_rule_performance` — the mart that produced the recall figure.
- `assert_match_rate_above_floor` deliberately tests `match_rate`, not
  `clean_match_rate`: the floor is about whether records *pair*, and a
  variance is a separate, named exception. Conflating them is how the 250 bps
  policy looked fine.
