# Recon Control Tower

**One-line takeaway:** a reconciliation that measures its own matching engine
against known answers, replays its exception queue as of any day without
snapshots, and ties the ledger to the bank to the cent — with two of its four
root-cause findings being defects in the reconciliation itself, caught by its
own scorecard.

**Dashboard:** [rizvi14.github.io/portfolio/recon-control-tower](https://rizvi14.github.io/portfolio/recon-control-tower/)
· **Findings:** [docs/rca](docs/rca/) · **Docs:** [matching rules](docs/matching-rules-spec.md), [taxonomy](docs/break-taxonomy.md), [severity & SLA](docs/severity-and-sla.md), [dbt walkthrough](docs/dbt-walkthrough.md), [Snowflake port plan](docs/snowflake-portability.md), [control roadmap](docs/control-roadmap.md), [requirements template](docs/requirements-template.md)

## The question

A fintech moves money over ACH, card and wire. Its ledger says one thing;
the partner bank and the card processor say another; the difference has to
be explained every day and signed off every month. The questions a
reconciliation function has to answer, in this order:

1. How many dollars are unexplained right now, and how old is the oldest?
2. Which differences are defects, which are money in transit, and who owns each?
3. Does the bank reconciliation foot — bank balance, plus every named
   reconciling item, equals the books?
4. Is the matching engine any good, and how would we know?

This project builds the whole thing from a cold clone in about fifteen
seconds, with no credentials and no warehouse account.

## Data

Synthetic, by design — so that every break has a label and the engine can be
graded rather than trusted.

| Source | Grain | Rows | Period |
|---|---|---|---|
| Internal ledger | one posting per transaction leg | 120,455 | 2026-03-02 → 2026-08-14 |
| Partner bank statement | one line per ACH / wire movement, free-text description | 35,971 | same |
| Card processor settlement | one line per settled card transaction | 85,046 | same |
| Ground truth (quarantined) | one label per injected break | 6,646 | same |

`src/generate.py` is seeded and deterministic (`data/raw/_manifest.json`
carries the SHA-256 of every file; CI fails if it drifts). Twenty break
injectors cover the real defect population — duplicate postings, returns
without an original, interchange netted by the processor, lifting fees,
transpositions, redelivered statement files, chargeback pairs — and, just as
deliberately, the things that are **not** defects: ACH riding the next file,
refunds settling in two legs, Notification-of-Change renames, FX rounding.
The engine is graded on leaving those alone.

Known caveats: no bank holidays; resolution of exceptions is simulated (a
deterministic lag straddling each severity's SLA, ~3% never resolving) and
posts no correcting entries — this is a tie-out, not a sub-ledger, by scope
decision.

## Method

```
generate (Parquet) ──► dbt over DuckDB ──► controls ──► static dashboard
```

**Matching** — a four-tier waterfall with anti-joins between tiers: exact
reference where it is unique on both sides (plus suffix recovery for
truncated wire references); aggregate by reference or batch; attribute on
amount + date + account identity with a blocking key and mutual-best
selection; and a tolerance tier that, on this population, correctly makes no
matches at all. A match is a *pair*; whether the amounts agree is judged
afterwards, so a variance stays linked to the records that produced it.

**Exceptions** — every candidate carries the window during which it was
open, so the queue as of any run date is a join against a date spine. No
snapshots, fully deterministic, replays from nothing. Classification is
resolved per run date: the same unmatched item is *in transit* on Tuesday and
*late* on Thursday. The threshold for "late" is calibrated per rail from the
observed p99 arrival lag of cleanly matched pairs — floored at the
contractual window, capped so a degrading rail cannot widen its own
definition of on-time. Settlements arriving in legs get their own clock.

**Tie-out** — the four-column bank reconciliation, built from match state
rather than from the queue, because an adjudicated exception leaves the
queue but its dollars stay in the clearing account until an entry posts.
What falls out is `awaiting_correction_cents`: explained, assigned, and
still sitting there. The bridge foots exactly across 360 rail-days, and the
month-end roll-forward (opening + opened − closed = closing) foots across
every month.

**Controls** — nine singular tests that encode what a recon function cannot
get wrong, each proven to fail under a deliberately broken configuration
before being kept. Two were rewritten after passing when they should not
have. A separate check walks dbt's manifest and refuses the build if any
model other than the scorecard can see ground truth.

**Scorecard** — `agg_matching_rule_performance` grades every verdict against
the labels at two grains: did the pipeline raise the right items
(transaction), and did each tier pair the right records (match). Precision
1.000, recall 0.991, zero false pairs on any tier.

Choices a reviewer would challenge, and why:

- *Precision at 1.000 looks too clean.* It is the result of two fixes in the
  first scored run (RCA-003), and it cost 36 late-ACH items that sit in a lag
  band shared with 515 legitimate in-transit items. That trade is stated,
  not hidden; on that rail at that lag, raising the exception means fourteen
  false alarms per real one.
- *The tie-out is zero by construction.* Yes — it is an arithmetic identity
  over match state, and the control on it is a footing check that catches a
  join that fans out or a leg counted twice. The number with information in
  it is the uncorrected balance, reported beside it.
- *Why DuckDB and not Snowflake?* Reproducibility from a cold clone. The SQL
  is near-ANSI and [docs/snowflake-portability.md](docs/snowflake-portability.md)
  is the honest list of what would change, including the one difference that
  changes every SLA in the queue without an error.

## Findings

- **ACH returns are being posted twice** — 148 in 120 days, seconds apart,
  $4.4M of ledger overstatement. Ingestion retry without an idempotency key.
  Found because tier 2 links both postings to the one bank line and reports
  the ratio: exactly 2.0×. → [RCA-001](docs/rca/RCA-001-duplicate-ach-returns.md)
- **Card settles net of interchange; the ledger books gross.** 1,490 items,
  1.8–2.2% short. The original 250 bps tolerance hid every one of them, and
  every $15–$35 wire lifting fee besides — wire recall on fees was 0.000.
  Tolerance is now per rail, and wire's is zero. → [RCA-002](docs/rca/RCA-002-interchange-gross-vs-net.md)
- **The business-day clock never subtracted weekends.** `date_diff('week')`
  in DuckDB is days ÷ 7; Friday → Monday read as three business days on
  every rail. Snowflake counts boundaries and would have been right. Same
  SQL, two answers. → [RCA-003](docs/rca/RCA-003-wire-cutoff-and-the-business-day-clock.md)
- **Identity must not be a name.** Under Notification of Change the bank
  rewrites the counterparty name. Keying tier 3 on the account recovers
  114/114; on the normalised name, 32/114 — and 82 items of money that had
  arrived would have been raised to Engineering as missing. → [RCA-004](docs/rca/RCA-004-noc-name-change-recall.md)
- **Tolerance is not free.** Every tolerated difference accumulates in the
  clearing account; the tie-out carries it as a named line so the cost of
  each basis point is a number.
- **ACH runs two business days past its contract at p99.** The settlement
  profile says so without any ground truth; it is a conversation with the
  partner, not a threshold to absorb.

## Running it

```bash
cd projects/recon-control-tower
py -3.13 -m venv .venv && .venv\Scripts\activate     # dbt-duckdb wheels stop at 3.13
pip install -r requirements.txt
python -m src.checks.run_controls                     # generate → dbt build → quarantine → control position
python -m src.export_dashboard                        # app/data/dashboard.js
```

Open `app/index.html` directly, or see the deployed copy. `dbt build` from
`dbt/` runs the 22 models, 4 seeds and 79 tests; `run_controls --skip-build`
prints the control position against the existing warehouse.

## Layout

```
src/generate.py, src/breaks.py     seeded generator and the twenty injectors
src/checks/                         ground-truth quarantine; control runner
src/export_dashboard.py             marts → app/data/dashboard.js
dbt/                                staging → contract → matching → exceptions → marts; macros; seeds; tests
docs/                               specs, taxonomy, roadmap, port plan; docs/rca/ the four findings
app/                                the static dashboard (no build step)
```
