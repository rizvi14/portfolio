# How I'd port this to Snowflake

This project runs on DuckDB because a reconciliation that anyone can
rebuild from a cold clone in ten seconds, with no credentials, is worth more
in a portfolio than one that needs a warehouse account. The SQL is written
near-ANSI with that port in mind. This page is the honest list of what would
change, in the order I would do it.

It is a plan, not a claim of having done it.

## What ports as-is

- Every model's structure: CTEs, window functions, `qualify`, `filter
  (where ...)` on aggregates, `group by all`, `list`/array aggregation with
  `unnest`. Snowflake supports all of these (`array_agg` / `flatten` for the
  last two — see below).
- The tests, the seeds, the vars, the macros' *logic*.
- The dbt project layout. `dbt-duckdb` → `dbt-snowflake` is a profile
  change; `external_location` on the raw source becomes an external table
  or a stage.

## What changes, and why it matters

### 1. `date_diff('week', ...)` — the one that bites silently

DuckDB: calendar days ÷ 7, truncated.
Snowflake: number of week boundaries crossed.

The classic business-day shortcut `date_diff('day') − 2 × date_diff('week')`
is **wrong in DuckDB and right in Snowflake**. This project does not use it
(RCA-003; `macros/business_days.sql` uses a weekday index instead), so the
port is safe — but the general lesson is that the same expression compiles
and runs in both and returns different numbers. `assert_business_day_clock_is_correct`
is the test that would catch it in either direction.

### 2. `regexp_extract` returns `''` in DuckDB and `NULL` in Snowflake

`stg_partner_bank_statement` wraps every extraction in `nullif(..., '')`
for DuckDB. On Snowflake (`regexp_substr`) that wrapper is redundant but
harmless. Removing it is optional; leaving it documents the trap.

### 3. Arrays

| DuckDB | Snowflake |
|---|---|
| `list(x)` | `array_agg(x)` |
| `unnest(arr)` in select | `lateral flatten(input => arr)` |
| `list_concat(a, b)` | `array_cat(a, b)` |
| `list_sort(string_split(s, ''))` (transposition check) | `array_sort(split(s, ''))` — Snowflake has `array_sort` since 2023 |
| `[a]` literal | `array_construct(a)` |

Mechanical, but touches every matching tier, `int_breaks__candidates`, and
the scorecard. I would wrap these in three small macros (`array_agg`,
`array_unnest`, `array_concat`) with `adapter.dispatch`, so the model SQL
stays dialect-free and the difference lives in one file.

### 4. Integer division

`n // 7` in DuckDB → `floor(n / 7)` in Snowflake. One place
(`weekday_index`).

### 5. `hash()`

Used only in the simulated resolution lag. `hash(break_id) % 100` → Snowflake
`abs(hash(break_id)) % 100` — Snowflake's `hash` is signed. Deterministic in
both, but the *values* differ, so the simulated resolution dates would
change and every number downstream of them would move. In production this
CTE does not exist; it is replaced by the case-management system's actual
close dates.

### 6. `generate_series` for the date spine

→ `table(generator(rowcount => n))` with `dateadd`. Or a proper calendar
dimension, which a production build should have anyway (holidays).

### 7. `quantile_cont`

→ `percentile_cont(p) within group (order by x)`. Three places, all in
`int_settlement_profile`.

### 8. `interval (expr) day`

DuckDB allows an expression inside `interval (...)`. Snowflake wants
`dateadd(day, expr, date)`. Appears in `within_settlement_window`,
`agg_recon_daily` (maturity), and `int_breaks__candidates` (resolution).

### 9. Sources and the generator

The generator writes Parquet. On Snowflake: `PUT` to an internal stage,
`COPY INTO` raw tables, or declare an external table over an S3/GCS
location. The `ground_truth` source stays a **separate source** so the
leakage check keeps working — it reads dbt's `manifest.json`, which is
warehouse-agnostic.

## What I would do differently on Snowflake, given the choice

- **Incremental `int_breaks__run_history`.** On DuckDB the full replay is
  two seconds. At production volume the date spine × candidates join is the
  expensive step, and it partitions cleanly by `run_date`, so an incremental
  model keyed on `(run_date, break_id)` with a lookback of the longest open
  window is the natural shape. Everything else stays full-refresh.
- **Clustering** `int_breaks__run_history` and `fct_gl_tieout` on
  `run_date` — every consumer filters on it.
- **Dynamic tables** for the marts, if the org uses them, so that the queue
  refreshes on a schedule without an orchestrator. I would keep the controls
  as dbt tests regardless; a dynamic table does not fail a build.
- **Streams** on the raw tables to drive the incremental model, replacing
  the `available_from` convention with actual arrival metadata — which is
  what `available_from` is standing in for.

## What I would not change

The design. Ground-truth-scored matching, the open-window queue in place of
snapshots, per-rail calibrated thresholds, the tie-out built from match
state, the controls with teeth. None of that is a DuckDB idea. It would be
the same reconciliation on any warehouse; the port is syntax.
