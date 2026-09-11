# The dbt project, model by model

A reading order for the `dbt/` directory. Each model's header comment says
why it exists; this page says how they fit together.

```
raw parquet ──► staging ──► int_recon_events__unioned ──► matching tiers 1–4 ──► int_matches__all
                                    │                                                │
                                    │                                                ├──► int_unmatched
                                    │                                                │
                                    └──────────────────────────────────────► int_breaks__candidates
                                                                                     │
                                                       int_settlement_profile ──────►│
                                                                                     ▼
                                                                          int_breaks__run_history
                                                                                     │
        ┌────────────────────┬──────────────────┬──────────────────┬─────────────────┤
        ▼                    ▼                  ▼                  ▼                 ▼
 fct_recon_breaks     agg_recon_daily     agg_break_aging     fct_gl_tieout    agg_matching_rule_performance
                                                                   │            (only reader of ground truth)
                                                                   ▼
                                                            rpt_close_summary
```

## Sources

`models/sources.yml` declares two sources over Parquet files the generator
wrote:

- `raw` — internal ledger, bank statement, card settlement, FX rates. The
  three systems of record.
- `ground_truth` — `break_truth`, the labels for every injected break.
  Declared as a **separate source** so that its consumers are visible in
  the DAG, and so that `src/checks/check_no_ground_truth_leakage.py` can
  assert that exactly one model reads it.

## Staging (`models/staging/`, views)

One model per source table. Rename, cast, sign, normalise. Nothing is
joined. The one piece of real work is `stg_partner_bank_statement`, which
parses trace numbers, IMADs, OBI references and counterparty names out of
the statement's free-text description with regular expressions — and every
`regexp_extract` is wrapped in `nullif(..., '')`, because DuckDB returns an
empty string rather than null on no match, and `coalesce` over a chain of
those short-circuits on the first empty one.

Sign convention is applied here and nowhere else (`signed_amount`).

## The contract (`int_recon_events__unioned`)

Every staged source is mapped to one shape. Every matching tier consumes
only this shape. Adding a rail is a staging model and one union branch.

The two columns that carry the design are `available_from` — the date the
record became *visible* to reconciliation, distinct from the date it
happened — and `counterparty_key` — account identity where it exists, name
only where it does not.

## Matching (`int_matches__tier1_exact` → `tier4_tolerance` → `int_matches__all`)

Four models, one per tier, each anti-joining every earlier tier's consumed
events. The spec is `docs/matching-rules-spec.md`. `int_matches__all` unions
them and judges each pair against tolerance. `int_unmatched` is the
complement.

Macros: `normalize_reference`, `normalize_counterparty`,
`amount_within_tolerance` (per rail), `within_settlement_window`.

## Exceptions (`int_breaks__candidates` → `int_breaks__run_history`)

`candidates` is the **static** view: every potential exception, classified
by shape, with the window `[open_from, open_until)` during which it was
open. Three sources feed it — orphans, variances, timing pairs — and keeping
them distinct is what makes the next model possible.

`run_history` is the **snapshot replacement**: a date spine joined against
those windows, so the queue as of any run date is a query rather than a
stored table. It resolves the age-dependent classification per run date
(`in_transit` / `partially_settled` / `timing_late`), computes the three
business-day clocks, and carries each item's signed impact on the
ledger-to-bank difference for the tie-out.

`int_settlement_profile` sits between them: the observed arrival-lag
distribution per rail, from which the investigation thresholds are
calibrated. It reads only cleanly matched pairs.

## Marts (`models/marts/`, tables)

| model | grain | for |
|---|---|---|
| `fct_recon_breaks` | open item, latest run | the queue |
| `fct_recon_matches` | match | audit trail behind the match rate |
| `agg_recon_daily` | run × rail | the morning numbers, in the order to read them |
| `agg_break_aging` | run × rail × severity × bucket × owner | the aged tail |
| `dim_break_type` | break code | conformed taxonomy |
| `fct_gl_tieout` | run × rail | four-column bank reconciliation |
| `rpt_close_summary` | month × rail | close package with roll-forward |
| `agg_matching_rule_performance` | (grain, subject, rail) | precision / recall per break type and per tier |

## Tests

**Generic** (`schema.yml` files): uniqueness, nullability, accepted values,
relationships to seeds, composite keys via the project's own
`unique_combination` test.

**Singular** (`tests/*.sql`): the nine reconciliation controls. Each file's
header says what it protects and, where relevant, how it was proven to have
teeth. `assert_in_transit_not_flagged_as_break` and
`assert_sla_flag_consistent` were both rewritten after passing under a
deliberately broken configuration.

`dbt build` runs models, seeds and all tests in DAG order and stops on the
first failure. `+store_failures: true` writes failing rows to a
`test_failures` schema so a red control can be read, not just seen.

## Vars

`dbt_project.yml` is the policy surface. Tolerances, settlement windows,
grace, the calibration ceiling, control floors, materiality — every number
someone might reasonably want to change is there, with a comment saying
what it absorbs and what it must not. Changing a reconciliation policy is a
one-line, reviewable diff.

## Runtime

dbt-core 1.12.4 with dbt-duckdb 1.11.0 on Python 3.13. The `dbt` on a
developer's PATH may be dbt-fusion, a different product; the control runner
invokes the venv's binary explicitly. Profile is committed — a local DuckDB
file, no credentials — because reproducibility from a cold clone is the
point.

## What is not here, on purpose

- **Incremental models.** The full build is ten seconds. Incrementality
  would add state to a pipeline whose selling point is having none.
- **Snapshots.** Replaced by the open-window design in `run_history`, which
  is cheaper, deterministic, and replays from nothing.
- **Packages.** `dbt_utils` would have been pulled in for one test; the
  test is fifteen lines.
