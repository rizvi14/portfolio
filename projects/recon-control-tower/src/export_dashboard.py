"""Export the dashboard's data from the warehouse.

The dashboard is a static page: no server, no database connection, nothing to
deploy but files. So the marts it reads are serialised here into one JSON
document and one JS wrapper (`window.RECON_DATA = ...`) that the page loads
with a plain <script> tag - which works from a file:// URL, from GitHub Pages,
and from anywhere else without a fetch.

Only mart-layer tables are read. The page never sees ground truth except
through agg_matching_rule_performance, the one model permitted to grade
against it.

Usage:
    python -m src.export_dashboard            # writes app/data/dashboard.{json,js}
    python -m src.export_dashboard --runs 90  # a longer trailing window
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
from decimal import Decimal
from pathlib import Path

import duckdb
import yaml

PROJECT = Path(__file__).resolve().parents[1]
DB_PATH = PROJECT / "data" / "processed" / "recon.duckdb"
OUT_DIR = PROJECT / "app" / "data"


def _rows(con: duckdb.DuckDBPyConnection, sql: str) -> list[dict]:
    cur = con.execute(sql)
    cols = [c[0] for c in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def _clean(o):
    if isinstance(o, dict):
        return {k: _clean(v) for k, v in o.items()}
    if isinstance(o, list):
        return [_clean(v) for v in o]
    if isinstance(o, (dt.date, dt.datetime)):
        return o.isoformat()
    if isinstance(o, Decimal):
        return float(o)
    return o


def export(runs: int) -> dict:
    con = duckdb.connect(str(DB_PATH), read_only=True)
    with (PROJECT / "dbt" / "dbt_project.yml").open(encoding="utf-8") as fh:
        dbt_vars = yaml.safe_load(fh)["vars"]
    with (PROJECT / "data" / "raw" / "_manifest.json").open(encoding="utf-8") as fh:
        manifest = json.load(fh)

    as_of = con.execute("select max(run_date) from main_marts.agg_recon_daily").fetchone()[0]

    daily = _rows(con, f"""
        select run_date, flow_type,
               unexplained_exposure_cents, open_breaks, oldest_open_break_bd, sla_breached,
               open_critical, in_transit_items, in_transit_cents,
               items_matured, items_matched, items_clean,
               match_rate, clean_match_rate, tier1_share,
               matched_tier1, matched_tier2, matched_tier3, matched_tier4
        from main_marts.agg_recon_daily
        where run_date > (select max(run_date) from main_marts.agg_recon_daily) - interval ({runs * 2}) day
        qualify dense_rank() over (order by run_date desc) <= {runs}
        order by run_date, flow_type""")

    queue = _rows(con, """
        select b.break_id, b.break_code, t.display_name, b.break_family, b.flow_type,
               b.severity, b.owner_team, b.exposure_cents, b.variance_cents,
               b.event_date, b.age_business_days, b.days_in_queue_bd, b.sla_clock_bd,
               b.sla_business_days, b.is_sla_breached, b.aging_bucket, b.match_rule,
               t.typical_root_cause, t.gl_treatment
        from main_marts.fct_recon_breaks b
        join main_marts.dim_break_type t using (break_code)
        where b.is_true_break
        order by b.exposure_cents desc""")

    in_transit = _rows(con, """
        select break_code, flow_type, count(*) as items, sum(exposure_cents) as exposure_cents
        from main_marts.fct_recon_breaks where not is_true_break
        group by all order by flow_type, break_code""")

    aging = _rows(con, """
        select flow_type, severity, aging_bucket, owner_team, open_breaks, exposure_cents, sla_breached
        from main_marts.agg_break_aging
        where as_of_date = (select max(as_of_date) from main_marts.agg_break_aging)""")

    tieout_latest = _rows(con, """
        select * from main_marts.fct_gl_tieout
        where run_date = (select max(run_date) from main_marts.fct_gl_tieout)
        order by flow_type""")

    tieout_trend = _rows(con, f"""
        select run_date, flow_type, difference_cents, open_queue_cents,
               awaiting_correction_cents, tolerated_variance_cents, unexplained_difference_cents
        from main_marts.fct_gl_tieout
        qualify dense_rank() over (order by run_date desc) <= {runs}
        order by run_date, flow_type""")

    close = _rows(con, """
        select close_month, close_date, flow_type,
               bank_balance_cents, gl_balance_cents, difference_cents, unexplained_difference_cents,
               open_queue_cents, awaiting_correction_cents, tolerated_variance_cents,
               open_breaks, open_exposure_cents, oldest_open_break_bd, sla_breached, open_critical,
               opening_breaks, opened_breaks, closed_breaks, raised_and_cleared_in_period,
               rollforward_gap, close_status
        from main_marts.rpt_close_summary
        order by close_month, flow_type""")

    scorecard_txn = _rows(con, """
        select p.subject, p.flow_type, p.n, p.tp, p.fn, p.fp, p.tn,
               p.precision, p.recall, p.f1, p.missed_exposure_cents, p.false_alarm_cents
        from main_marts.agg_matching_rule_performance p
        where grain = 'transaction' and subject <> 'no_injection'
        order by flow_type, subject""")

    scorecard_match = _rows(con, """
        select subject, flow_type, n, tp, fp, precision, false_alarm_cents
        from main_marts.agg_matching_rule_performance
        where grain = 'match' order by flow_type, subject""")

    profile = _rows(con, """
        select flow_type, observed_pairs, policy_window_bd, lag_p50_bd, lag_p95_bd, lag_p99_bd,
               lag_max_bd, floor_bd, ceiling_bd, investigation_threshold_bd, threshold_is_capped,
               tail_over_policy_bd, observed_splits, leg_gap_p99_bd, partial_completion_threshold_bd
        from main_intermediate.int_settlement_profile order by flow_type""")

    taxonomy = _rows(con, "select * from main_marts.dim_break_type order by is_true_break desc, break_family, break_code")

    # the headline, in the order it should be read
    latest = [d for d in daily if d["run_date"] == as_of]
    tp = sum(r["tp"] for r in scorecard_txn)
    fn = sum(r["fn"] for r in scorecard_txn)
    fp = sum(r["fp"] for r in scorecard_txn)
    headline = {
        "as_of": as_of,
        "unexplained_exposure_cents": sum(d["unexplained_exposure_cents"] for d in latest),
        "open_breaks": sum(d["open_breaks"] for d in latest),
        "sla_breached": sum(d["sla_breached"] for d in latest),
        "open_critical": sum(d["open_critical"] for d in latest),
        "oldest_open_break_bd": max(d["oldest_open_break_bd"] for d in latest),
        "in_transit_items": sum(d["in_transit_items"] for d in latest),
        "in_transit_cents": sum(d["in_transit_cents"] for d in latest),
        "items_matured": sum(d["items_matured"] for d in latest),
        "items_matched": sum(d["items_matched"] for d in latest),
        "match_rate": sum(d["items_matched"] for d in latest) / sum(d["items_matured"] for d in latest),
        "clean_match_rate": sum(d["items_clean"] for d in latest) / sum(d["items_matured"] for d in latest),
        "tieout_foots": all(t["unexplained_difference_cents"] == 0 for t in tieout_latest),
        "awaiting_correction_cents": sum(t["awaiting_correction_cents"] for t in tieout_latest),
        "rollforward_foots": all(c["rollforward_gap"] == 0 for c in close),
        "precision": tp / (tp + fp) if tp + fp else None,
        "recall": tp / (tp + fn) if tp + fn else None,
        "false_positives": fp,
        "false_negatives": fn,
    }

    con.close()
    return _clean({
        "meta": {
            "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
            "as_of": as_of,
            "trailing_runs": runs,
            "seed": manifest["seed"],
            "period": {"start": manifest["start_date"], "end": manifest["end_date"]},
            "transactions": manifest["transactions"],
            "injected_breaks": manifest["injected_breaks"],
            "rails": ["ach", "card", "wire"],
            "vars": dbt_vars,
        },
        "headline": headline,
        "daily": daily,
        "queue": queue,
        "in_transit": in_transit,
        "aging": aging,
        "tieout": {"latest": tieout_latest, "trend": tieout_trend},
        "close": close,
        "scorecard": {"transaction": scorecard_txn, "match": scorecard_match},
        "profile": profile,
        "taxonomy": taxonomy,
    })


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--runs", type=int, default=60, help="trailing run dates to include in trends")
    args = ap.parse_args()

    data = export(args.runs)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
    (OUT_DIR / "dashboard.json").write_text(payload + "\n", encoding="utf-8")
    (OUT_DIR / "dashboard.js").write_text(f"window.RECON_DATA = {payload};\n", encoding="utf-8")
    kb = len(payload.encode("utf-8")) / 1024
    print(f"wrote app/data/dashboard.json and dashboard.js ({kb:,.0f} KB): "
          f"{len(data['queue'])} open breaks, {len(data['daily'])} daily rows, as of {data['meta']['as_of']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
