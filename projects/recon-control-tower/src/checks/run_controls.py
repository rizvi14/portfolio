"""Run the reconciliation end to end and report the control position.

One command, from a cold clone, that answers "is the reconciliation in a state
someone could sign?":

    generate  ->  dbt build  ->  ground-truth quarantine  ->  control summary

`dbt build` already fails on any broken control, so this script is not the
enforcement layer - it is the page a recon lead would read after the build,
with every number that matters and the threshold it was judged against
printed next to it. CI runs it and attaches the output to the run; a human
reads the same thing locally.

Thresholds are read from dbt_project.yml so that there is exactly one place
a policy number lives. The comment in that file claiming they are "mirrored"
here was true of an earlier draft and is now wrong in the safe direction.

Usage:
    python -m src.checks.run_controls                # full pipeline
    python -m src.checks.run_controls --skip-build   # summary only, warehouse as-is
    python -m src.checks.run_controls --seed 7       # different world, same controls
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

import duckdb
import yaml

PROJECT = Path(__file__).resolve().parents[2]
DBT_DIR = PROJECT / "dbt"
DB_PATH = PROJECT / "data" / "processed" / "recon.duckdb"


# --------------------------------------------------------------------------- run
def _run(cmd: list[str], cwd: Path) -> None:
    print(f"\n$ {' '.join(cmd)}  (in {cwd.relative_to(PROJECT) if cwd != PROJECT else '.'})", flush=True)
    result = subprocess.run(cmd, cwd=cwd)
    if result.returncode != 0:
        raise SystemExit(f"step failed with exit code {result.returncode}: {cmd[0]}")


def _dbt() -> list[str]:
    # the venv's dbt-core, never whatever `dbt` resolves to on PATH (which on
    # a developer machine may be dbt-fusion, a different product)
    exe = Path(sys.executable).with_name("dbt.exe" if os.name == "nt" else "dbt")
    return [str(exe)] if exe.exists() else [sys.executable, "-m", "dbt.cli.main"]


def build(seed: int) -> None:
    _run([sys.executable, "-m", "src.generate", "--seed", str(seed)], PROJECT)
    _run(_dbt() + ["build", "--profiles-dir", ".", "--no-partial-parse"], DBT_DIR)
    _run([sys.executable, "-m", "src.checks.check_no_ground_truth_leakage"], PROJECT)


# ----------------------------------------------------------------------- report
def _vars() -> dict:
    with (DBT_DIR / "dbt_project.yml").open(encoding="utf-8") as fh:
        return yaml.safe_load(fh)["vars"]


def _usd(cents: int | float | None) -> str:
    return f"${(cents or 0) / 100:,.2f}"


class Report:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.warnings: list[str] = []

    def line(self, label: str, value: str, ok: bool | None = None, threshold: str = "") -> None:
        mark = "  " if ok is None else ("ok" if ok else "!!")
        print(f"  {mark}  {label:<44} {value:>18}  {threshold}")
        if ok is False:
            self.failures.append(label)

    def warn(self, label: str, value: str, note: str) -> None:
        print(f"  ~~  {label:<44} {value:>18}  {note}")
        self.warnings.append(label)

    def header(self, text: str) -> None:
        print(f"\n{text}\n{'-' * len(text)}")


def summarise(v: dict) -> Report:
    con = duckdb.connect(str(DB_PATH), read_only=True)
    q = lambda sql: con.execute(sql).fetchall()  # noqa: E731
    r = Report()

    as_of = q("select max(as_of_date) from main_marts.fct_recon_breaks")[0][0]
    print(f"\nRECONCILIATION CONTROL POSITION  as of {as_of}")

    # --- 1. exposure first ---------------------------------------------------
    r.header("1. Unexplained exposure and the aged tail")
    for flow, expo, breaks, oldest, breached, critical in q("""
        select flow_type, unexplained_exposure_cents, open_breaks,
               oldest_open_break_bd, sla_breached, open_critical
        from main_marts.agg_recon_daily
        where run_date = (select max(run_date) from main_marts.agg_recon_daily)
        order by flow_type"""):
        r.line(f"{flow}: unexplained exposure", _usd(expo))
        r.line(f"{flow}: open true breaks", f"{breaks:,}")
        # the aged tail is a review item, not a build failure: ~3% of breaks
        # are simulated as never resolving precisely so that this line has
        # something to say. A real shop would page on it; CI should not go
        # red on it forever.
        if oldest > v["sla_breach_age_days"] * 6:
            r.warn(f"{flow}: oldest open break", f"{oldest} bd",
                   f"aged tail - over {v['sla_breach_age_days'] * 6} bd")
        else:
            r.line(f"{flow}: oldest open break", f"{oldest} bd")
        r.line(f"{flow}: past SLA", f"{breached:,}")
        if critical:
            r.warn(f"{flow}: critical open", f"{critical}", "critical severity open at run date")

    # --- 2. match rate, on matured items -------------------------------------
    r.header("2. Match rate (matured items only)")
    floor = v["match_rate_floor_by_flow"]
    for flow, rate, clean, t1, matured in q("""
        select flow_type, match_rate, clean_match_rate, tier1_share, items_matured
        from main_marts.agg_recon_daily
        where run_date = (select max(run_date) from main_marts.agg_recon_daily)
        order by flow_type"""):
        r.line(f"{flow}: match rate", f"{rate:.4f}", ok=rate >= floor, threshold=f"floor {floor}")
        r.line(f"{flow}: clean match rate", f"{clean:.4f}")
        r.line(f"{flow}: tier-1 share of matches", f"{t1:.4f}")
    overall = q("""
        select sum(items_matched) / sum(items_matured)
        from main_marts.agg_recon_daily
        where run_date = (select max(run_date) from main_marts.agg_recon_daily)""")[0][0]
    r.line("overall match rate", f"{overall:.4f}",
           ok=overall >= v["match_rate_floor_overall"],
           threshold=f"floor {v['match_rate_floor_overall']}")

    # --- 3. does the tie-out foot ---------------------------------------------
    r.header("3. Bank reconciliation tie-out")
    tol = v["gl_tieout_tolerance_cents"]
    for flow, diff, unexplained, awaiting, tolerated in q("""
        select flow_type, difference_cents, unexplained_difference_cents,
               awaiting_correction_cents, tolerated_variance_cents
        from main_marts.fct_gl_tieout
        where run_date = (select max(run_date) from main_marts.fct_gl_tieout)
        order by flow_type"""):
        r.line(f"{flow}: GL - bank", _usd(diff))
        r.line(f"{flow}: unexplained", _usd(unexplained), ok=abs(unexplained) <= tol,
               threshold=f"tolerance {_usd(tol)}")
        r.line(f"{flow}: awaiting correction", _usd(awaiting))
        r.line(f"{flow}: tolerated variance", _usd(tolerated))

    # --- 4. month-end ----------------------------------------------------------
    r.header("4. Latest month-end")
    for month, flow, opening, opened, closed, closing, gap, status in q("""
        select close_month, flow_type, opening_breaks, opened_breaks, closed_breaks,
               open_breaks, rollforward_gap, close_status
        from main_marts.rpt_close_summary
        where close_month = (select max(close_month) from main_marts.rpt_close_summary)
        order by flow_type"""):
        r.line(f"{flow}: roll-forward {opening} + {opened} - {closed}", f"= {closing}",
               ok=gap == 0, threshold="" if gap == 0 else f"gap {gap}")
        r.line(f"{flow}: close status", status)

    # --- 5. is the matcher any good -------------------------------------------
    r.header("5. Matcher scorecard (graded against injected ground truth)")
    tp, fn, fp = q("""
        select sum(tp), sum(fn), sum(fp) from main_marts.agg_matching_rule_performance
        where grain = 'transaction'""")[0]
    r.line("precision", f"{tp / (tp + fp):.4f}", ok=tp / (tp + fp) >= 0.98, threshold="floor 0.98")
    r.line("recall", f"{tp / (tp + fn):.4f}", ok=tp / (tp + fn) >= 0.98, threshold="floor 0.98")
    for subject, flow, n, recall, missed in q("""
        select subject, flow_type, n, recall, missed_exposure_cents
        from main_marts.agg_matching_rule_performance
        where grain = 'transaction' and recall < 1 order by recall"""):
        r.warn(f"{flow}: {subject} recall", f"{recall:.4f}", f"n={n}, missed {_usd(missed)}")
    for subject, flow, fp_n, cents in q("""
        select subject, flow_type, fp, false_alarm_cents
        from main_marts.agg_matching_rule_performance
        where grain = 'match' and fp > 0"""):
        r.line(f"{flow}: {subject} false matches", f"{fp_n}", ok=False,
               threshold=f"would hide {_usd(cents)}")

    # --- 6. rails --------------------------------------------------------------
    r.header("6. Settlement behaviour vs. contract")
    for flow, policy, p99, thr, capped, tail in q("""
        select flow_type, policy_window_bd, lag_p99_bd, investigation_threshold_bd,
               threshold_is_capped, tail_over_policy_bd
        from main_intermediate.int_settlement_profile order by flow_type"""):
        r.line(f"{flow}: policy T+{policy}, observed p99 T+{int(p99)}", f"threshold {thr} bd")
        if capped:
            r.warn(f"{flow}: threshold capped", "", "rail's tail has run past the ceiling - escalate the partner")
        elif tail > 0:
            r.warn(f"{flow}: tail over contract", f"+{tail} bd", "consistently late vs. contractual window")

    con.close()
    return r


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--skip-build", action="store_true", help="summarise the existing warehouse only")
    args = ap.parse_args()

    if not args.skip_build:
        build(args.seed)
    elif not DB_PATH.exists():
        print(f"no warehouse at {DB_PATH}; run without --skip-build first", file=sys.stderr)
        return 2

    report = summarise(_vars())

    print()
    if report.failures:
        print(f"CONTROL FAILURES ({len(report.failures)}):")
        for f in report.failures:
            print(f"  - {f}")
        return 1
    print(f"all controls within threshold; {len(report.warnings)} item(s) flagged for attention")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
