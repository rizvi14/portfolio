# Root-cause analyses

Four investigations from the first scored runs of the reconciliation. Each
one starts from a number on the scorecard or the queue, follows it to a
cause, and ends with what changed and who owns what did not.

| | Finding | Rail | Root cause sits with |
|---|---|---|---|
| [RCA-001](RCA-001-duplicate-ach-returns.md) | ACH returns posted twice, seconds apart | ACH | Engineering — return handler is not idempotent |
| [RCA-002](RCA-002-interchange-gross-vs-net.md) | Card settles net of interchange; ledger books gross. A 250 bps tolerance hid all of it, and hid every wire lifting fee too | Card, wire | Accounting policy; and our own tolerance design |
| [RCA-003](RCA-003-wire-cutoff-and-the-business-day-clock.md) | Post-cutoff wires raised as late; the business-day clock never subtracted weekends | All | Reconciliation — `date_diff('week')` means something different in DuckDB than in Snowflake |
| [RCA-004](RCA-004-noc-name-change-recall.md) | Notification of Change rewrites the counterparty name; keying identity on the name would have lost 72% of recall | ACH | Rule design; and Product — NOCs are not being processed |

Two of the four (002 and 003) are defects in the reconciliation itself,
found by the reconciliation's own scorecard. That is the intended use of
`agg_matching_rule_performance`: a recall of 0.000 on a break type is not a
statistic, it is a bug report with the rule's name on it.

## Format

Header table (code, rail, owner, severity, item count, exposure, status);
summary; how it surfaced; investigation; root cause; contributing factors;
remediation split into *in place* and *proposed*, with the owner named; what
would have caught it earlier. Numbers come from the warehouse and are
reproducible from a cold clone with the seed in `data/raw/_manifest.json`.
