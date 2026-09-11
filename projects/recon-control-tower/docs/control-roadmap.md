# Reconciliation control roadmap

Where this reconciliation is, where it should go, and in what order. Written
as the document a new reconciliation lead would put in front of Finance and
Engineering in their first month.

## Where it is

| capability | state |
|---|---|
| Three rails (ACH, card, wire) against ledger, bank statement and processor settlement | built |
| Four-tier matching waterfall with per-rule performance measurement | built |
| Exception queue replayable as of any run date, no snapshots | built |
| Exception taxonomy with owner, SLA and GL treatment; SLA clock from actionable date | built |
| Investigation threshold calibrated per rail from observed behaviour | built |
| Four-column bank reconciliation that foots to the cent; month-end roll-forward | built |
| Nine reconciliation controls run on every build; CI refuses a failing one | built |
| Static dashboard for the queue, trend, tie-out, scorecard and rail profile | built — GitHub Pages |
| Resolution workflow | **simulated** — stated in the README |
| Correcting journal entries | **not modelled** — tie-out only, by scope decision |
| Holiday calendar | not modelled |
| Alerting integration | thresholds defined; not wired |

## Principles the roadmap is built on

1. **Lead with dollars, not percentages.** Unexplained exposure and the
   oldest open break are the headline. Match rate is third, and a
   duplicated file can raise it.
2. **Measure the rules.** No matching rule is trusted until its precision
   and recall have been read off a scorecard. In production that scorecard
   is fed by adjudicated outcomes and back-tests rather than injected
   truth; the mart it feeds is already built.
3. **A control that cannot fail is not a control.** Every new test gets
   deliberately broken once before it is merged (RCA-003 § threshold).
4. **The queue must stay readable.** False positives are treated as
   defects with the same weight as false negatives, because the cost of a
   noisy queue is that the real break sits in a list nobody reads.

## Next two quarters

### Q4 2026 — close the loop with Accounting

| item | why now | owner |
|---|---|---|
| **Post correcting entries from resolved breaks.** Adjudicating a break should generate the journal that clears it from the clearing account. `awaiting_correction_cents` is $5.6M on ACH and growing because nothing does this today. | It is the largest number on the close package and the only one with no next step. | Accounting + Engineering |
| **Interchange at settlement.** Book the fee per transaction from the processor file instead of a monthly lump (RCA-002). | Removes ~12 exceptions per day that are policy, not defects. | Accounting |
| **Idempotent return handler** (RCA-001). | $4.4M of duplicated postings in 120 days; a retry storm would be worse. | Engineering |
| **Holiday calendar** joined in `business_days_between`. | Every Fed holiday currently ages every open item by one day. | Reconciliation |

### Q1 2027 — widen the population

| item | why | owner |
|---|---|---|
| **Fourth rail.** Whichever funds flow is next — the contract in `int_recon_events__unioned` and the checklist in `docs/matching-rules-spec.md` § adding a rail exist so that this is a staging model and a union, not a project. | The test of whether the architecture is real. | Reconciliation |
| **Multi-currency.** Tolerance and the tie-out already work in minor units; what is missing is FX on the external side and a tolerated-variance line that will finally be non-trivial. | Wires are the first place this bites. | Reconciliation + Treasury |
| **Partner scorecard.** `int_settlement_profile` already measures each rail's tail over contract (ACH +2 bd). Publish it monthly to the relationship owner. | It is a conversation to have, not a number to absorb. | Banking Partner relationship |
| **Shadow-mode rule deployment.** A new or changed matching rule runs, reports its pairs, and consumes none until its match-grain precision has been read for a cycle. | Tier 4 is the tier most tempting to loosen when the queue is long. | Reconciliation |

## Later

- **Adjudication capture.** Analyst dispositions recorded as labels, so
  the scorecard runs on real outcomes and rule changes can be back-tested
  against last quarter's resolved breaks.
- **Alerting.** `run_controls.py` already knows the thresholds. Wire the
  `!!` lines to a pager and the `~~` lines to a channel.
- **Audit pack.** The close summary plus the control run output plus the
  dbt manifest for that build, archived per period. Everything is already
  produced; this is a retention decision.

## What is deliberately not on it

- **Machine-learned matching.** The waterfall's tier-4 precision is
  1.000 with zero matches, which is to say the deterministic rules leave
  nothing for a model to do on this population. A model earns a place when
  a rail's tier-3/4 share is high *and* its false-match rate is measured;
  neither is true yet.
- **Auto-resolution.** Finding is the engine's job. Closing is a person's.
