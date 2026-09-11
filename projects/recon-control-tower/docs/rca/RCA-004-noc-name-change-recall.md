# RCA-004 — Notification of Change: matching on a name that the bank is allowed to rewrite

| | |
|---|---|
| **Break code** | none — these are clean matches. This RCA is about a *near miss* in rule design. |
| **Rail** | ACH |
| **Owner** | Reconciliation / Product (NOC handling) |
| **Items** | 114 ACH credits where the receiving bank issued a NOC and the statement name changed |
| **Recall, as built** | 114 / 114 (tier 3, account identity) |
| **Recall, name-keyed alternative** | 32 / 114 = 28% |
| **Status** | Design confirmed; NOC processing gap raised with Product |

## Summary

A Notification of Change (NACHA C-codes) is the receiving bank telling the
originator that something about the receiver's account details is wrong and
here is the correction — most commonly the account holder's name. The next
statement line for that receiver carries the corrected name. Nothing about
the money has changed.

In this period, 114 ACH credits arrived with a rewritten counterparty name
**and** without the trace reference the ledger had booked them under. Tier 1
(reference) could not match them. Whether tier 3 could depended entirely on
one design choice: what "same counterparty" means.

## What the names looked like

| ledger | bank statement, after NOC |
|---|---|
| ALDERPOINT DENTAL LABS | ALDERPOINT DENTAL LABS DBA ALDERPOINT HOLDINGS |
| KESTREL CAPITAL HOLDINGS | KESTREL CAPITAL HOLDINGS DBA KESTREL HOLDINGS |
| FOXGLOVE STUDIO INC | FOXGLOVE STUDIO INCORPORATED |
| STONEGATE CAPITAL CORP | STONEGATE CAPITAL CORP DBA STONEGATE HOLDINGS |

After `normalize_counterparty` (upper-case, strip punctuation, drop legal
suffixes — LLC, INC, CORP, HOLDINGS, DBA and so on):

| ledger | bank | equal? |
|---|---|---|
| ALDERPOINT DENTAL | ALDERPOINT DENTAL ALDERPOINT | no |
| KESTREL CAPITAL | KESTREL CAPITAL KESTREL | no |
| FOXGLOVE STUDIO | FOXGLOVE STUDIO | **yes** |
| STONEGATE CAPITAL | STONEGATE CAPITAL STONEGATE | no |

Normalisation rescues the suffix-only cases (32 of 114). It cannot rescue a
trading-as name, because the DBA introduces a new token that survives every
suffix rule. A fuzzier comparison — prefix match, token overlap — would
recover more of these, and would also start pairing "ALDERPOINT DENTAL" with
"ALDERPOINT DENTAL SUPPLY" across the street. The failure mode of loosening
name matching is a false match, and a false match on tier 3 hides a real
difference behind a green number.

## The design decision

`int_recon_events__unioned` defines the counterparty key as:

```
counterparty_key    stable identity: account hash where the source provides
                    one, normalised name only where it does not
```

ACH statement lines carry the receiver's account (hashed at staging); so does
the ledger. Tier 3 blocks on `(flow, currency, amount, counterparty_key)`.
For ACH, `counterparty_key` is the account hash. The name is carried
alongside as `counterparty_norm` for display and for the card rail, where
there is no account to key on.

Under NOC, the account is exactly the thing that did *not* change. 114 of
114 matched at tier 3 with the account key. Measured against the same 114
pairs, equality on `counterparty_norm` — the obvious choice, and the only one
available on a rail without account identifiers — holds for 32.

## Root cause of the near miss

Identity was being modelled on a **display attribute**. Names are what humans
read; they are also what banks are contractually permitted to rewrite, what
free-text parsing mangles, and what customers change when they incorporate,
merge or start trading under a brand. An attribute that three different
parties can legitimately alter is not an identity, however stable it looks
in a sample.

The account hash is boring, opaque, and changed by nobody. That is what an
identity key should look like.

## Why this is an RCA and not a footnote

Because the alternative would have passed every test that existed at the
time. 32 of 114 is a 72% recall loss on a break type that is not a break,
which means the cost would have shown up as **82 internal orphans**, aged
past the ACH window, raised as `missing_external`, owner Engineering, SLA 2
business days — for money that had arrived. Engineering would have
investigated the first few, found the funds, and learned that
`missing_external` on ACH is usually nothing. That is how a queue trains its
readers to ignore it, and it would have happened before anyone noticed the
rule was wrong.

The scorecard is what makes the comparison a number rather than an
argument. `agg_matching_rule_performance` reports `ach_noc_name_change` as
114 items, zero raised, zero false positives — the correct outcome for a
non-break — and the name-keyed variant can be run against the same ground
truth in one line.

## Remediation

**In place:**

- Account identity as the tier-3 key on every rail that provides it. Name is
  a fallback, not a primary.
- `normalize_counterparty` retains suffix stripping for the card rail, with
  the DBA limitation documented in the macro.

**Raised with Product:**

- **NOCs are not being processed.** The whole point of a Notification of
  Change is that the originator updates its records so the next entry goes
  out correct. The ledger still carries the pre-NOC name for all 114
  receivers, which means every future entry to them will arrive with a name
  mismatch — and, under NACHA rules, continuing to originate with known-stale
  details is a compliance exposure, not just a matching nuisance. The
  reconciliation can absorb the mismatch indefinitely; that is not the same
  as it being fine.
- Monitoring: NOC volume per receiver per month. One is a correction. Several
  is a receiver whose details the platform keeps getting wrong.

## Related

- RCA-003 — the other rule-design finding from the first scored run.
- `docs/matching-rules-spec.md` § tier 3, for the blocking key and the
  mutual-best rule that keeps a loose key from producing a false pair.
