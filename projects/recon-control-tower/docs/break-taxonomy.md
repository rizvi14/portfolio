# Break taxonomy

Every exception the engine can raise, what it means, who owns it, and what
the books do about it. The source of truth is `dbt/seeds/seed_break_taxonomy.csv`;
this page is the reading version. `assert_break_types_exhaustive` fails the
build if the engine emits a code that is not in the seed — an exception with
no owner and no SLA is an item that ages while everyone assumes someone else
has it.

## The line that matters

`is_true_break` separates a **reconciling item** from an **exception**.

- A reconciling item is a difference between the books and the bank that is
  *expected* — money in transit, a settlement arriving in legs. It appears
  on the bank reconciliation, it has dollars, and nobody needs to do
  anything. It is not work.
- An exception is a difference that is *not* expected. It has an owner, an
  SLA, and a GL treatment. It is work.

The dashboard leads with exceptions. The close package needs both.

## Reconciling items (`is_true_break = false`)

| code | family | when | GL |
|---|---|---|---|
| `in_transit` | timing | the counterpart has not arrived and the item is younger than the rail's investigation threshold | cash in transit; no action |
| `partially_settled` | timing | at least one external leg has arrived; the remainder is inside the observed leg-to-leg gap | cash partially applied; no action |

Both are **age-dependent**: the same item becomes `timing_late` on the run
date it outlives its threshold. Classification is resolved per run date in
`int_breaks__run_history`, which is why the queue can be replayed as of any
day.

## Exceptions (`is_true_break = true`)

### Timing

| code | rail | severity | owner | SLA (bd) | typical root cause |
|---|---|---|---|---:|---|
| `timing_late` | all | medium | Banking Partner | 3 | partner file delay, cutoff miss |

### Orphans — one side only

| code | rail | severity | owner | SLA | typical root cause | GL treatment |
|---|---|---|---|---:|---|---|
| `missing_external` | all | high | Engineering | 2 | payment never left the platform, or partner never posted it | clearing overstated |
| `missing_internal` | all | high | Finance | 2 | unbooked bank item; misrouted ledger entry | cash overstated vs GL |
| `duplicate_internal` | all | high | Engineering | 1 | ingestion retry without an idempotency key (RCA-001) | clearing overstated by the duplicate |
| `duplicate_external` | all | **critical** | Banking Partner | 1 | statement file redelivered and re-ingested | cash overstated; **raises** the match rate |
| `return_unlinked` | ACH | high | Product | 2 | return references an original booked under a different reference, or never booked | returns payable understated |
| `bank_adjustment` | all | low | Finance | 5 | partner fee, interest, memo item (BAI 555) | book to fees / interest |
| `chargeback_pair` | card | medium | Product | 5 | dispute lifecycle entries lacking the original ARN | net to zero once paired; provision if unpaired |

### Variances — paired, amounts disagree

| code | rail | severity | owner | SLA | typical root cause | GL treatment |
|---|---|---|---|---:|---|---|
| `fee_interchange` | card | medium | Finance | 3 | processor remits net; ledger books gross (RCA-002) | reclass to interchange expense |
| `fee_lifting` | wire | medium | Finance | 3 | intermediary deducted a fee in transit | reclass to bank fees |
| `auth_capture` | card | low | Product | 5 | tip added, or partial capture after auth | adjust to settled amount |
| `transposition` | all | high | Engineering | 1 | keying error on one side; both amounts are the same multiset of digits | correct the erroneous side |
| `amount_variance_other` | all | high | Finance | 2 | unknown | recon difference until explained |

`amount_variance_other` is the catch-all and should be rare. A rising count
means a new fee shape or a new defect that needs its own code — the
taxonomy is meant to grow.

## How a code is assigned

Static classification (`int_breaks__candidates`) decides *what the item is*
from its shape: which side is missing, what hints the source carried (a
return code, a BAI code, a redelivery flag), the ratio of aggregate sums,
the ratio of variance to principal. Age-dependent classification
(`int_breaks__run_history`) decides *whether it is a break today*.

Severity is the taxonomy default, escalated by exposure against
`seed_severity_matrix`: any item over $25,000 is critical; over $5,000 is at
least high.

## Changing the taxonomy

A new code is one seed row plus one branch in the classifier, in the same
commit. The build refuses either without the other.
