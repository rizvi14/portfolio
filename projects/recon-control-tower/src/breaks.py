"""Break injectors.

Each injector takes an ideal, perfectly-reconciling transaction and perturbs it
into a realistic reconciliation break, then records a ground-truth row saying
exactly what it did.

The ground truth is the point of this project: because we know which records
were deliberately broken and how, the matching waterfall in dbt can be *scored*
for precision and recall instead of merely asserted to work. Nothing in the
matching path may read it - enforced by
src/checks/check_no_ground_truth_leakage.py.

Two structurally different break families come out of these injectors, and the
distinction drives the whole dbt design:

  * ORPHAN breaks    - a record exists on one side with no counterpart at all
                       (missing, duplicated, or bank-originated items).
  * VARIANCE breaks  - the two sides DO match on a reference, but the amounts
                       disagree by more than tolerance. The pair stays linked,
                       which is what makes root-cause analysis tractable.

Real reconciliation teams care about that split because it routes the
investigation differently: an orphan is usually a pipeline or timing problem, a
variance is usually a booking-policy or fee-modelling problem.
"""

from __future__ import annotations

import datetime as dt
from typing import Callable

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


def _gt(txn, break_type, expected_side, amount_cents=0, has_difference=True, **detail):
    """Append a ground-truth row describing an injected break.

    expected_side is what a correct matcher should conclude:
      internal_only  - orphan on our books
      external_only  - orphan on the bank/processor side
      variance       - matched pair, amounts disagree beyond tolerance
      none           - NOT a defect; a correct matcher clears this cleanly

    The two truth flags are deliberately separate, and the distinction is the
    one most often got wrong:

      has_difference  - the two sides genuinely differ in amount or timing
      is_true_break   - that difference is a DEFECT requiring investigation

    A timing lag, a known fee, and FX rounding all have a difference and are
    not breaks - they are *reconciling items*. Counting them as exceptions
    inflates the queue and is the fastest way to lose an analyst's trust in the
    control. Only `is_true_break` should ever page a human.
    """
    txn["ground_truth"].append(
        {
            "txn_id": txn["txn_id"],
            "flow_type": txn["flow_type"],
            "break_type": break_type,
            "expected_side": expected_side,
            "truth_has_difference": bool(has_difference),
            "truth_is_true_break": expected_side != "none",
            "injected_amount_cents": int(amount_cents),
            "detail": "; ".join(f"{k}={v}" for k, v in detail.items()),
        }
    )


def _shift(date_str: str, days: int) -> str:
    return (dt.date.fromisoformat(date_str) + dt.timedelta(days=days)).isoformat()


def _next_business_day(date_str: str, days: int) -> str:
    """Advance by `days` calendar days, then roll forward off Sat/Sun.

    Fedwire and ACH settle only on banking days, so a Friday-initiated payment
    can land the following Monday or Tuesday. This is the mechanism behind the
    weekend-cutoff phantom breaks investigated in RCA-003.
    """
    d = dt.date.fromisoformat(date_str) + dt.timedelta(days=days)
    while d.weekday() >= 5:
        d += dt.timedelta(days=1)
    return d.isoformat()


# ---------------------------------------------------------------------------
# ACH
# ---------------------------------------------------------------------------


def ach_in_transit(rng, txn):
    """Expected timing lag: the bank record has simply not arrived yet.

    This is NOT a defect. It is the control's most important false-positive
    trap - an item unmatched as of today's run but perfectly matchable in two
    days. A recon process that pages someone for these is worse than useless,
    because analysts learn to ignore the queue.
    """
    lag = rng.randint(1, 2)
    for row in txn["external"]:
        row["available_from"] = _shift(row["available_from"], lag)
    _gt(txn, "ach_in_transit", "none", lag_days=lag)


def ach_timing_cutoff(rng, txn):
    """Bank record arrives late enough to cross the investigation SLA."""
    lag = rng.randint(3, 6)
    for row in txn["external"]:
        row["available_from"] = _shift(row["available_from"], lag)
        row["value_date"] = _next_business_day(row["value_date"], lag)
    _gt(txn, "ach_timing_cutoff", "internal_only", lag_days=lag)


def ach_missing_at_bank(rng, txn):
    """Internal entry posted; nothing ever arrives from the bank."""
    amt = txn["internal"][0]["amount_cents"]
    txn["external"].clear()
    _gt(txn, "ach_missing_at_bank", "internal_only", amount_cents=amt)


def ach_return_unlinked(rng, txn):
    """A return lands from the bank with no originating internal entry.

    Models the case where the original debit was booked under a different
    reference, or never booked at all, so the R-code return has nothing to
    attach to.
    """
    code = rng.choice(["R01", "R02", "R03", "R05", "R10", "R29"])
    amt = txn["internal"][0]["amount_cents"]
    txn["internal"].clear()
    for row in txn["external"]:
        row["description"] = f"ACH RETURN {code} TRACE#{txn['ref']} UNMATCHED ORIGIN"
        row["amount_signed_cents"] = -abs(row["amount_signed_cents"])
        row["bai_code"] = "475"
    _gt(txn, "ach_return_unlinked", "external_only", amount_cents=amt, return_code=code)


def ach_duplicate_return(rng, txn):
    """Ingestion retry posts the same return twice internally.

    Both copies carry the identical trace number, so the reference becomes
    non-unique on our side. The waterfall routes that to aggregate matching,
    where the internal sum comes to exactly 2x the bank amount - the signature
    RCA-001 keys on.
    """
    original = txn["internal"][0]
    dupe = dict(original)
    dupe["ledger_entry_id"] = original["ledger_entry_id"] + "-RETRY"
    # Seconds later, not days: the tell-tale sign of a retry rather than a
    # genuine second payment.
    ts = dt.datetime.fromisoformat(original["posted_at_utc"])
    gap = rng.randint(2, 9)
    dupe["posted_at_utc"] = (ts + dt.timedelta(seconds=gap)).isoformat(sep=" ")
    dupe["entry_type"] = "return"
    txn["internal"].append(dupe)
    _gt(
        txn,
        "ach_duplicate_return",
        "internal_only",
        amount_cents=original["amount_cents"],
        seconds_apart=gap,
    )


def ach_batch_aggregation(rng, txn):
    """The bank settles a whole ACH batch as one net credit.

    N internal entries share a batch id; the bank sends a single line with no
    per-item trace. Only aggregate many-to-one matching clears this, which is
    why the waterfall needs a dedicated tier for it.
    """
    n = rng.randint(3, 6)
    base = txn["internal"][0]
    total = base["amount_cents"]
    for i in range(n - 1):
        sib = dict(base)
        sib["ledger_entry_id"] = f"{base['ledger_entry_id']}-B{i + 1}"
        sib["amount_cents"] = max(100, int(base["amount_cents"] * rng.uniform(0.4, 1.6)))
        sib["external_ref"] = ""  # individual traces are not exposed in a batch
        sib["counterparty_name"] = rng.choice(txn["counterparty_pool"])
        total += sib["amount_cents"]
        txn["internal"].append(sib)
    base["external_ref"] = ""
    for row in txn["external"]:
        sign = 1 if row["amount_signed_cents"] > 0 else -1
        row["amount_signed_cents"] = sign * total
        row["description"] = f"ACH BATCH SETTLEMENT BATCH#{txn['batch_id']} {n} ITEMS"
    _gt(txn, "ach_batch_aggregation", "none", amount_cents=total,
        has_difference=False, batch_size=n)


def ach_noc_name_change(rng, txn):
    """A Notification of Change renames the counterparty at the bank.

    The trace number is also absent from this statement line, so the item must
    fall through to attribute matching - where the changed name defeats a
    name-based key. This is the evidence behind RCA-004's recommendation that
    account hash must outrank name in the match key.
    """
    old = txn["internal"][0]["counterparty_name"]
    new = old.replace("LLC", "L.L.C.").replace("INC", "INCORPORATED")
    if new == old:
        new = f"{old} DBA {old.split()[0]} HOLDINGS"
    for row in txn["external"]:
        row["description"] = f"ACH CREDIT CO={new} NO TRACE PROVIDED"
    _gt(txn, "ach_noc_name_change", "none", has_difference=False,
        old_name=old, new_name=new)


# ---------------------------------------------------------------------------
# Card
# ---------------------------------------------------------------------------


def card_interchange_net(rng, txn):
    """Processor remits net of interchange; the ledger books gross.

    The variance is therefore exactly the fee: about 1.8% + $0.10. That tight
    functional relationship between variance and principal is what identifies
    the cause in RCA-002 - and it is why a blanket tolerance would paper over a
    real booking defect rather than fix it.
    """
    row = txn["external"][0]
    fee = int(round(row["auth_amount_cents"] * 0.018)) + 10
    row["settled_amount_cents"] = row["auth_amount_cents"] - fee
    row["interchange_fee_cents"] = fee
    _gt(txn, "card_interchange_net", "variance", amount_cents=fee, fee_bps=180)


def card_auth_capture_drift(rng, txn):
    """Settled amount differs from authorised: a tip, or a partial capture."""
    row = txn["external"][0]
    if rng.random() < 0.6:
        delta = int(round(row["auth_amount_cents"] * rng.uniform(0.15, 0.22)))
        kind = "tip_added"
    else:
        delta = -int(round(row["auth_amount_cents"] * rng.uniform(0.2, 0.5)))
        kind = "partial_capture"
    row["settled_amount_cents"] = row["auth_amount_cents"] + delta
    _gt(txn, "card_auth_capture_drift", "variance", amount_cents=delta, kind=kind)


def card_missing_settlement(rng, txn):
    """Authorisation expires without ever settling."""
    amt = txn["internal"][0]["amount_cents"]
    txn["external"].clear()
    _gt(txn, "card_missing_settlement", "internal_only", amount_cents=amt)


def card_partial_refund(rng, txn):
    """One internal refund arrives as two partial processor settlements.

    The sums agree, so correct aggregate matching clears this with no break. A
    naive one-to-one matcher raises two false positives instead - which is
    exactly what the precision score is there to catch.
    """
    row = txn["external"][0]
    whole = row["settled_amount_cents"]
    first = int(whole * rng.uniform(0.35, 0.65))
    row["settled_amount_cents"] = first
    row["auth_amount_cents"] = first
    second = dict(row)
    second["processor_txn_id"] = row["processor_txn_id"] + "-P2"
    second["settled_amount_cents"] = whole - first
    second["auth_amount_cents"] = whole - first
    lag = rng.randint(1, 2)
    second["settlement_date"] = _shift(row["settlement_date"], lag)
    second["available_from"] = _shift(row["available_from"], lag)
    txn["external"].append(second)
    _gt(txn, "card_partial_refund", "none", amount_cents=whole,
        has_difference=False, splits=2)


def card_chargeback_representment(rng, txn):
    """A chargeback, then its representment: two offsetting processor entries.

    Net effect is zero, but neither leg carries the original auth code, so both
    look like orphans until they are netted against each other.
    """
    row = txn["external"][0]
    amt = row["settled_amount_cents"]
    row["settled_amount_cents"] = -amt
    row["auth_code"] = ""
    row["arn"] = f"CB{txn['seq']:012d}"
    rep = dict(row)
    rep["processor_txn_id"] = row["processor_txn_id"] + "-REP"
    rep["settled_amount_cents"] = amt
    rep["arn"] = f"RP{txn['seq']:012d}"
    lag = rng.randint(5, 20)
    rep["settlement_date"] = _shift(row["settlement_date"], lag)
    rep["available_from"] = _shift(row["available_from"], lag)
    txn["external"].append(rep)
    _gt(txn, "card_chargeback_representment", "external_only", amount_cents=amt)


# ---------------------------------------------------------------------------
# Wire
# ---------------------------------------------------------------------------


def wire_fx_rounding(rng, txn):
    """Sub-cent FX rounding: a variance well inside tolerance.

    The second false-positive trap. These must NOT be flagged; if they are, the
    exception queue fills with noise.
    """
    row = txn["external"][0]
    delta = rng.choice([-3, -2, -1, 1, 2, 3])
    row["amount_signed_cents"] += delta
    _gt(txn, "wire_fx_rounding", "none", amount_cents=delta)


def wire_fee_deducted(rng, txn):
    """An intermediary bank lifts a fee out of the wire in transit."""
    row = txn["external"][0]
    fee = rng.choice([1500, 2000, 2500, 3500])
    sign = 1 if row["amount_signed_cents"] > 0 else -1
    row["amount_signed_cents"] -= sign * fee
    row["description"] = row["description"] + f" LIFTING FEE USD{fee / 100:.2f}"
    _gt(txn, "wire_fee_deducted", "variance", amount_cents=fee)


def wire_cutoff_weekend(rng, txn):
    """Initiated after the Fedwire cutoff on a Friday: the value date rolls."""
    rolled = ""
    for row in txn["external"]:
        row["value_date"] = _next_business_day(row["value_date"], 1)
        row["available_from"] = _next_business_day(row["available_from"], 1)
        rolled = row["value_date"]
    _gt(txn, "wire_cutoff_weekend", "internal_only", rolled_to=rolled)


def wire_amount_transposition(rng, txn):
    """Manual keying error: two adjacent digits swapped.

    1,234.00 becomes 1,243.00 - small enough to slip past someone eyeballing a
    statement, large enough to blow tolerance. Which is precisely why this needs
    an automated control rather than a review step.
    """
    row = txn["external"][0]
    digits = list(str(abs(row["amount_signed_cents"])))
    if len(digits) >= 3:
        for _ in range(6):
            i = rng.randrange(len(digits) - 1)
            if digits[i] != digits[i + 1]:
                digits[i], digits[i + 1] = digits[i + 1], digits[i]
                break
    new = int("".join(digits))
    sign = 1 if row["amount_signed_cents"] > 0 else -1
    delta = sign * new - row["amount_signed_cents"]
    row["amount_signed_cents"] = sign * new
    _gt(txn, "wire_amount_transposition", "variance", amount_cents=delta)


def wire_duplicate_send(rng, txn):
    """Operator resubmits a wire the bank had already accepted."""
    original = txn["internal"][0]
    dupe = dict(original)
    dupe["ledger_entry_id"] = original["ledger_entry_id"] + "-DUP"
    ts = dt.datetime.fromisoformat(original["posted_at_utc"])
    dupe["posted_at_utc"] = (
        ts + dt.timedelta(minutes=rng.randint(3, 40))
    ).isoformat(sep=" ")
    txn["internal"].append(dupe)
    _gt(
        txn,
        "wire_duplicate_send",
        "internal_only",
        amount_cents=original["amount_cents"],
    )


# ---------------------------------------------------------------------------
# Cross-flow
# ---------------------------------------------------------------------------


def bank_only_adjustment(rng, txn):
    """Bank-originated item with no internal counterpart: fee, interest, adj."""
    kind, amt = rng.choice(
        [
            ("ANALYSIS FEE", -rng.randint(500, 4000)),
            ("INTEREST CREDIT", rng.randint(100, 2500)),
            ("RETURNED ITEM FEE", -rng.randint(1000, 3500)),
            ("ADJUSTMENT MEMO", rng.choice([-1, 1]) * rng.randint(200, 9000)),
        ]
    )
    txn["internal"].clear()
    for row in txn["external"]:
        row["amount_signed_cents"] = amt
        row["description"] = f"{kind} NO REFERENCE"
        row["bai_code"] = "555"
    _gt(txn, "bank_only_adjustment", "external_only", amount_cents=abs(amt), kind=kind)


def external_duplicate_redelivery(rng, txn):
    """The partner bank redelivers a statement file after an outage.

    The same logical line arrives twice under a new file_id. A matcher keyed on
    bank_ref alone will happily match BOTH copies to the single internal item -
    which *raises* the reported match rate while overstating cash. That is the
    whole argument for a double-match control: match rate is a gameable metric,
    and this is the break that games it. See RCA-003.
    """
    if not txn["external"]:
        return
    row = txn["external"][0]
    dupe = dict(row)
    lag = rng.randint(1, 3)
    if "bank_txn_id" in row:  # partner-bank statement line
        dupe["bank_txn_id"] = row["bank_txn_id"] + "-RD"
        dupe["file_id"] = row["file_id"] + "-REDELIVERY"
        dupe["is_redelivered"] = True
        amt = abs(row["amount_signed_cents"])
    else:  # card processor settlement row
        dupe["processor_txn_id"] = row["processor_txn_id"] + "-RD"
        amt = abs(row["settled_amount_cents"])
    dupe["available_from"] = _shift(row["available_from"], lag)
    txn["external"].append(dupe)
    _gt(
        txn,
        "external_duplicate_redelivery",
        "external_only",
        amount_cents=amt,
        redelivered_after_days=lag,
    )


def wire_reference_truncation(rng, txn):
    """The bank truncates our IMAD reference in the free-text OBI field.

    Only the trailing characters survive, so an exact reference join misses.
    Reference normalization plus suffix matching recovers it, which is why
    normalize_counterparty/reference exists as a macro rather than inline SQL.
    Not a defect: a correctly-built matcher clears this silently.
    """
    if not txn["external"]:
        return
    ref = txn["ref"]
    kept = ref[-12:]
    for row in txn["external"]:
        row["description"] = f"FEDWIRE IN OBI/.../{kept} TRUNCATED BY BANK"
    _gt(
        txn,
        "wire_reference_truncation",
        "none",
        has_difference=False,
        full_ref=ref,
        surviving_suffix=kept,
    )


# ---------------------------------------------------------------------------
# registry: break_type -> (injector, applicable flows, relative weight)
# ---------------------------------------------------------------------------

INJECTORS: dict[str, tuple[Callable, tuple[str, ...], float]] = {
    # ACH
    "ach_in_transit": (ach_in_transit, ("ach",), 22.0),
    "ach_timing_cutoff": (ach_timing_cutoff, ("ach",), 9.0),
    "ach_missing_at_bank": (ach_missing_at_bank, ("ach",), 4.0),
    "ach_return_unlinked": (ach_return_unlinked, ("ach",), 6.0),
    "ach_duplicate_return": (ach_duplicate_return, ("ach",), 5.0),
    "ach_batch_aggregation": (ach_batch_aggregation, ("ach",), 8.0),
    "ach_noc_name_change": (ach_noc_name_change, ("ach",), 5.0),
    # Card
    "card_interchange_net": (card_interchange_net, ("card",), 12.0),
    "card_auth_capture_drift": (card_auth_capture_drift, ("card",), 9.0),
    "card_missing_settlement": (card_missing_settlement, ("card",), 4.0),
    "card_partial_refund": (card_partial_refund, ("card",), 6.0),
    "card_chargeback_representment": (card_chargeback_representment, ("card",), 4.0),
    # Wire
    "wire_fx_rounding": (wire_fx_rounding, ("wire",), 10.0),
    "wire_fee_deducted": (wire_fee_deducted, ("wire",), 7.0),
    "wire_cutoff_weekend": (wire_cutoff_weekend, ("wire",), 6.0),
    "wire_amount_transposition": (wire_amount_transposition, ("wire",), 3.0),
    "wire_duplicate_send": (wire_duplicate_send, ("wire",), 2.0),
    "wire_reference_truncation": (wire_reference_truncation, ("wire",), 6.0),
    # Cross-flow
    "bank_only_adjustment": (bank_only_adjustment, ("ach", "wire"), 5.0),
    "external_duplicate_redelivery": (
        external_duplicate_redelivery,
        ("ach", "card", "wire"),
        3.0,
    ),
}


def pick_injector(rng, flow: str):
    """Weighted draw among the injectors valid for this funds flow."""
    eligible = [(name, spec) for name, spec in INJECTORS.items() if flow in spec[1]]
    weights = [spec[2] for _, spec in eligible]
    name, spec = rng.choices(eligible, weights=weights, k=1)[0]
    return name, spec[0]
