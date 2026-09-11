"""Synthetic funds-flow generator for the Reconciliation Control Tower.

Emits three systems of record that a reconciliation team would actually be
handed - an internal ledger, a partner-bank statement, and a card-processor
settlement file - plus a quarantined ground-truth table describing every break
that was deliberately injected.

Design decisions that matter, and why:

1. TWO PHASES. Phase A builds a world that reconciles *perfectly*: one event
   fans out into all three sides, derived from the same facts. Phase B mutates
   one side and logs a truth row. Run with --no-breaks to prove Phase A ties
   100% with zero exceptions; if the harness itself leaked differences, every
   precision number downstream would be fiction. `make verify-clean` does this.

2. INTEGER MINOR UNITS. Money is `*_cents BIGINT`, never a float. Float money
   plus tolerance matching manufactures phantom breaks out of representation
   error - you end up investigating IEEE 754 instead of the bank.

3. PARQUET, NOT DUCKDB. The generator never writes the analytics database.
   DuckDB is single-writer; a generator holding the file while dbt tries to
   build would lock-error. The generator emits immutable files, dbt owns the
   warehouse. It also means CSV type-mangling never touches the amounts we are
   reconciling on.

4. DETERMINISM. One seeded Random threaded through everything, no module-level
   random, no datetime.now(). `_manifest.json` records the seed, row counts and
   a sha256 per file, so "regenerate and diff the manifest" is a real test.

Usage:
    python src/generate.py --seed 42
    python src/generate.py --seed 42 --no-breaks       # clean-world proof
    python src/generate.py --seed 42 --extra-breaks external_duplicate_redelivery=40
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import pathlib
import random
import sys

import duckdb

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import breaks as brk  # noqa: E402

HERE = pathlib.Path(__file__).resolve().parent.parent
RAW = HERE / "data" / "raw"

# ---------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------

CONFIG = {
    "start_date": "2026-03-02",
    "days": 120,
    # Daily transaction counts by funds flow. Card dominates by count, wire by
    # value - which is why exposure and count tell different stories.
    "daily_volume": {"ach": 260, "card": 700, "wire": 40},
    # Share of transactions that get an injected break. Higher than a healthy
    # production rail (0.1-2%) on purpose: the portfolio needs enough
    # exceptions per category to analyse. Stated openly in the README.
    "break_rate": 0.055,
    "n_accounts": 240,
    "n_counterparties": 180,
    # Normal settlement lag in business days, by flow. An external record
    # landing inside this window is timing, not a break - and match rate is
    # only measured on items that have had this long to settle.
    "settle_lag": {"ach": 1, "card": 2, "wire": 0},
    "fx_share_wire": 0.12,
}

# Amount distributions, in cents: (min, median, max) fed to a triangular draw.
AMOUNTS = {
    "ach": (5_000, 180_000, 9_500_000),
    "card": (500, 6_400, 320_000),
    "wire": (150_000, 2_400_000, 90_000_000),
}

# Money movement maps to a GL account by flow and direction. Kept deliberately
# small - this project does tie-out, not full journal entries.
GL_MAP = {
    ("ach", "credit"): "1020",  # Cash in Transit - ACH
    ("ach", "debit"): "1050",  # ACH Clearing - Outbound
    ("card", "credit"): "1040",  # Card Clearing
    ("card", "debit"): "1040",
    ("wire", "credit"): "1025",  # Cash in Transit - Wire
    ("wire", "debit"): "1060",  # Wire Clearing
}

ORG_WORDS = [
    "ACME", "NORTHWIND", "CEDARBROOK", "HALCYON", "BRIGHTPATH", "IRONWOOD",
    "MERIDIAN", "SUNDIAL", "KESTREL", "BLUEBIRCH", "STONEGATE", "LATTICE",
    "FAIRMOUNT", "VERIDIAN", "QUARRY", "TIDEWATER", "OAKLINE", "PINNACLE",
    "WESTFORD", "GRANITE", "ALDERPOINT", "CLEARWATER", "FOXGLOVE", "HARBORLY",
]
ORG_TAILS = ["LLC", "INC", "CORP", "HOLDINGS", "PARTNERS", "LABS", "GROUP", "CO"]
ORG_MIDS = ["LOGISTICS", "PAYROLL", "SUPPLY", "MEDIA", "CAPITAL", "FOODS",
            "SYSTEMS", "DESIGN", "FREIGHT", "DENTAL", "STUDIO", "ROBOTICS"]

CURRENCIES = ["EUR", "GBP"]


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


def business_days(start: str, n: int) -> list[str]:
    """n consecutive calendar days from start, weekends excluded."""
    out, d = [], dt.date.fromisoformat(start)
    while len(out) < n:
        if d.weekday() < 5:
            out.append(d.isoformat())
        d += dt.timedelta(days=1)
    return out


def next_business_day(date_str: str, days: int) -> str:
    d = dt.date.fromisoformat(date_str) + dt.timedelta(days=days)
    while d.weekday() >= 5:
        d += dt.timedelta(days=1)
    return d.isoformat()


def make_entities(rng: random.Random):
    counterparties = []
    seen = set()
    while len(counterparties) < CONFIG["n_counterparties"]:
        name = f"{rng.choice(ORG_WORDS)} {rng.choice(ORG_MIDS)} {rng.choice(ORG_TAILS)}"
        if name not in seen:
            seen.add(name)
            counterparties.append(name)
    accounts = [f"ACC{i:06d}" for i in range(1, CONFIG["n_accounts"] + 1)]
    return accounts, counterparties


def cpty_hash(name: str) -> str:
    """Stable pseudo account-number hash for a counterparty.

    Matching on this rather than on the display name is the RCA-004 fix: names
    get rewritten by Notification-of-Change and by bank free-text mangling,
    account identity does not.
    """
    return hashlib.sha256(name.encode()).hexdigest()[:16]


def draw_amount(rng: random.Random, flow: str) -> int:
    lo, mid, hi = AMOUNTS[flow]
    return int(rng.triangular(lo, hi, mid))


# ---------------------------------------------------------------------------
# Phase A: the clean world
# ---------------------------------------------------------------------------


def make_txn(rng, seq, date, flow, accounts, counterparties) -> dict:
    """One transaction, fanned out into a perfectly-reconciling set of records."""
    amount = draw_amount(rng, flow)
    direction = "credit" if rng.random() < (0.58 if flow != "card" else 0.22) else "debit"
    cpty = rng.choice(counterparties)
    account = rng.choice(accounts)
    txn_id = f"TXN{seq:09d}"
    lag = CONFIG["settle_lag"][flow]
    value_date = next_business_day(date, lag)
    hour = rng.randint(9, 19)
    posted = f"{date} {hour:02d}:{rng.randint(0, 59):02d}:{rng.randint(0, 59):02d}"

    currency, fx_rate = "USD", 1.0
    if flow == "wire" and rng.random() < CONFIG["fx_share_wire"]:
        currency = rng.choice(CURRENCIES)
        fx_rate = round(rng.uniform(1.04, 1.31), 6)

    # References: the genuinely shared key per rail.
    if flow == "ach":
        ref = f"{rng.randint(10**14, 10**15 - 1)}"          # 15-digit trace
    elif flow == "card":
        # 23-digit Acquirer Reference Number. Auth codes are only 6 digits and
        # recur constantly, so they cannot serve as a shared unique key; the
        # ARN is what processor settlement files and ledgers actually share.
        ref = f"2{rng.randint(10**21, 10**22 - 1)}"
    else:
        ref = f"IMAD{date.replace('-', '')}B1Q{rng.randint(10**6, 10**7 - 1)}"

    batch_id = f"BATCH{date.replace('-', '')}{rng.randint(1, 9)}"
    signed = amount if direction == "credit" else -amount

    internal = [
        {
            "ledger_entry_id": f"LE{seq:09d}",
            "txn_id": txn_id,
            "flow_type": flow,
            "entry_type": "payment",
            "account_id": account,
            "counterparty_name": cpty,
            "counterparty_account_hash": cpty_hash(cpty),
            "direction": direction,
            "amount_cents": amount,
            "currency": currency,
            "fx_rate": fx_rate,
            "posted_at_utc": posted,
            "effective_date": date,
            "gl_account_code": GL_MAP[(flow, direction)],
            "external_ref": ref,
            "batch_id": batch_id,
            "available_from": date,
        }
    ]

    external: list[dict] = []
    if flow == "card":
        # An authorisation is a memo hold, NOT a GL event. Only the clearing /
        # settlement side is money movement, so only it is reconciled here.
        external.append(
            {
                "processor_txn_id": f"PRC{seq:09d}",
                "auth_code": f"{rng.randint(100000, 999999)}",
                "arn": ref,
                "auth_amount_cents": amount,
                "settled_amount_cents": amount,
                "interchange_fee_cents": 0,
                "network_fee_cents": 0,
                "currency": currency,
                "direction": direction,
                "settlement_date": value_date,
                "merchant_ref": cpty,
                "available_from": value_date,
            }
        )
    else:
        verb = "CREDIT" if direction == "credit" else "DEBIT"
        if flow == "ach":
            desc = f"ACH {verb} SETTLEMENT TRACE#{ref} CO={cpty}"
            bai = "165" if direction == "credit" else "455"
        else:
            desc = f"FEDWIRE {'IN' if direction == 'credit' else 'OUT'} {ref} REF {cpty}"
            bai = "195" if direction == "credit" else "495"
        external.append(
            {
                "bank_txn_id": f"BNK{seq:09d}",
                "file_id": f"STMT{value_date.replace('-', '')}",
                "statement_date": value_date,
                "value_date": value_date,
                "amount_signed_cents": signed,
                "currency": currency,
                "description": desc,
                "bai_code": bai,
                "batch_id": batch_id,
                "available_from": value_date,
                "is_redelivered": False,
            }
        )

    return {
        "txn_id": txn_id,
        "seq": seq,
        "flow_type": flow,
        "ref": ref,
        "batch_id": batch_id,
        "internal": internal,
        "external": external,
        "ground_truth": [],
        "counterparty_pool": counterparties,
    }


# ---------------------------------------------------------------------------
# warehouse emit
# ---------------------------------------------------------------------------

DDL = {
    "internal_ledger": """
        ledger_entry_id VARCHAR, txn_id VARCHAR, flow_type VARCHAR,
        entry_type VARCHAR, account_id VARCHAR, counterparty_name VARCHAR,
        counterparty_account_hash VARCHAR, direction VARCHAR,
        amount_cents BIGINT, currency VARCHAR, fx_rate DOUBLE,
        posted_at_utc TIMESTAMP, effective_date DATE, gl_account_code VARCHAR,
        external_ref VARCHAR, batch_id VARCHAR, available_from DATE
    """,
    "bank_statement_lines": """
        bank_txn_id VARCHAR, file_id VARCHAR, statement_date DATE,
        value_date DATE, amount_signed_cents BIGINT, currency VARCHAR,
        description VARCHAR, bai_code VARCHAR, batch_id VARCHAR,
        available_from DATE, is_redelivered BOOLEAN
    """,
    "card_settlement": """
        processor_txn_id VARCHAR, auth_code VARCHAR, arn VARCHAR,
        auth_amount_cents BIGINT, settled_amount_cents BIGINT,
        interchange_fee_cents BIGINT, network_fee_cents BIGINT,
        currency VARCHAR, direction VARCHAR, settlement_date DATE,
        merchant_ref VARCHAR, available_from DATE
    """,
    "break_truth": """
        txn_id VARCHAR, flow_type VARCHAR, break_type VARCHAR,
        expected_side VARCHAR, truth_has_difference BOOLEAN,
        truth_is_true_break BOOLEAN, injected_amount_cents BIGINT,
        detail VARCHAR
    """,
    "fx_rates": """
        rate_date DATE, currency VARCHAR, usd_per_unit DOUBLE
    """,
}

COLS = {name: [c.strip().split()[0] for c in ddl.strip().rstrip(",").split(",")]
        for name, ddl in DDL.items()}


def write_parquet(con, name: str, rows: list[dict]) -> int:
    """Stage rows through a temp CSV, load with an explicit schema, emit Parquet.

    DuckDB's executemany autocommits per row and is far too slow for 100k+
    rows. A bulk CSV read is ~100x faster, and because the column types are
    declared from DDL rather than inferred, the amounts still land as BIGINT
    and the dates as DATE - the CSV is a transport, never a type authority.
    """
    cols = COLS[name]
    types = dict(
        (c.strip().split()[0], " ".join(c.strip().split()[1:]))
        for c in DDL[name].strip().rstrip(",").split(",")
    )
    tmp = RAW / f"_{name}.csv"
    with tmp.open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        for r in rows:
            w.writerow(["" if r.get(c) is None else r.get(c) for c in cols])
    schema = ", ".join(f"'{c}': '{t}'" for c, t in types.items())
    con.execute(
        f"CREATE OR REPLACE TABLE {name} AS "
        f"SELECT * FROM read_csv('{tmp.as_posix()}', header=true, "
        f"columns={{{schema}}}, nullstr='')"
    )
    tmp.unlink()
    out = (RAW / f"{name}.parquet").as_posix()
    con.execute(f"COPY {name} TO '{out}' (FORMAT PARQUET)")
    return con.execute(f"SELECT count(*) FROM {name}").fetchone()[0]


def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--days", type=int, default=CONFIG["days"])
    ap.add_argument("--scale", type=float, default=1.0,
                    help="multiply daily volumes (CI runs 0.25)")
    ap.add_argument("--no-breaks", action="store_true",
                    help="clean-world proof: must reconcile 100%%")
    ap.add_argument("--extra-breaks", default="",
                    help="force extra injections, e.g. ach_duplicate_return=50")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    RAW.mkdir(parents=True, exist_ok=True)

    accounts, counterparties = make_entities(rng)
    dates = business_days(CONFIG["start_date"], args.days)

    forced: list[str] = []
    for part in filter(None, args.extra_breaks.split(",")):
        name, _, n = part.partition("=")
        forced.extend([name.strip()] * int(n or 1))
    rng.shuffle(forced)

    internal_rows: list[dict] = []
    bank_rows: list[dict] = []
    card_rows: list[dict] = []
    truth_rows: list[dict] = []
    injected = 0
    seq = 0

    for date in dates:
        for flow, base_volume in CONFIG["daily_volume"].items():
            volume = max(1, int(base_volume * args.scale))
            for _ in range(volume):
                seq += 1
                txn = make_txn(rng, seq, date, flow, accounts, counterparties)

                # Phase B: perturb one side and log the truth.
                if not args.no_breaks:
                    name = None
                    if forced:
                        candidate = forced[-1]
                        spec = brk.INJECTORS.get(candidate)
                        if spec and flow in spec[1]:
                            name, fn = forced.pop(), spec[0]
                    if name is None and rng.random() < CONFIG["break_rate"]:
                        name, fn = brk.pick_injector(rng, flow)
                    if name is not None:
                        fn(rng, txn)
                        injected += 1

                internal_rows.extend(txn["internal"])
                truth_rows.extend(txn["ground_truth"])
                for row in txn["external"]:
                    (card_rows if "processor_txn_id" in row else bank_rows).append(row)

    # Daily FX rates, walked as a random walk so the series looks like a series.
    fx_rows = []
    levels = {c: rng.uniform(1.05, 1.28) for c in CURRENCIES}
    for date in business_days(CONFIG["start_date"], args.days + 10):
        for cur in CURRENCIES:
            levels[cur] = max(0.8, levels[cur] * (1 + rng.gauss(0, 0.004)))
            fx_rows.append(
                {"rate_date": date, "currency": cur,
                 "usd_per_unit": round(levels[cur], 6)}
            )

    con = duckdb.connect()
    counts = {
        "internal_ledger": write_parquet(con, "internal_ledger", internal_rows),
        "bank_statement_lines": write_parquet(con, "bank_statement_lines", bank_rows),
        "card_settlement": write_parquet(con, "card_settlement", card_rows),
        "break_truth": write_parquet(con, "break_truth", truth_rows),
        "fx_rates": write_parquet(con, "fx_rates", fx_rows),
    }

    manifest = {
        "seed": args.seed,
        "scale": args.scale,
        "days": args.days,
        "start_date": CONFIG["start_date"],
        "end_date": dates[-1],
        "breaks_enabled": not args.no_breaks,
        "transactions": seq,
        "injected_breaks": injected,
        "row_counts": counts,
        "sha256": {
            f"{n}.parquet": sha256(RAW / f"{n}.parquet") for n in counts
        },
    }
    (RAW / "_manifest.json").write_text(json.dumps(manifest, indent=2))

    print(f"transactions      {seq:>9,}")
    for name, n in counts.items():
        print(f"{name:<18}{n:>9,}")
    print(f"injected breaks   {injected:>9,}"
          f"  ({injected / max(seq, 1):.2%} of transactions)")
    if args.no_breaks:
        print("\nclean-world mode: this dataset must reconcile 100% with 0 exceptions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
