-- How good is the matcher, measured - not asserted.
--
-- THIS IS THE ONLY MODEL PERMITTED TO READ GROUND TRUTH. Everything upstream
-- decided what it decided without seeing the answers; here the answers are
-- opened and the verdicts are graded. src/checks/check_no_ground_truth_leakage.py
-- fails the build if any other node's ancestry touches the truth source.
--
-- Two questions, two grains:
--
--   TRANSACTION grain - did the pipeline reach the right VERDICT?
--       truth says "true break"   -> was an exception raised?        (recall)
--       truth says "no defect"    -> was the item left alone?        (precision)
--     Reported per break type, so a low-recall type points at exactly which
--     rule or tolerance is hiding it.
--
--   MATCH grain - did each tier pair the RIGHT records?
--       a false match (records from two different transactions paired) is
--       worse than an unmatched item: it hides a real difference behind a
--       green number. Reported per tier as precision, with the DOLLARS a false
--       match would have hidden - the number that actually matters.
--
-- Production has no ground truth. The analogue is shadow-mode rule deployment,
-- analyst adjudication of a sample, and back-testing on resolved breaks; this
-- mart is the shape those feed into.

with truth as (
    select
        txn_id,
        regexp_extract(txn_id, '([0-9]{9})', 1)             as txn_seq,
        flow_type,
        break_type,
        expected_side,
        truth_has_difference,
        truth_is_true_break,
        injected_amount_cents
    from {{ source('ground_truth', 'break_truth') }}
),

-- every event, tagged with the transaction it came from. In this synthetic
-- dataset the originating sequence is embedded in every id; in production
-- this join would run through adjudicated case ids instead.
events as (
    select
        event_id,
        side,
        flow_type,
        regexp_extract(event_id, '([0-9]{9})', 1)           as txn_seq,
        abs(signed_amount_cents)                            as amount_cents
    from {{ ref('int_recon_events__unioned') }}
),

-- the matcher's final verdict per event
verdict as (
    select
        e.*,
        case
            when u.event_id is not null                     then 'orphan'
            when m.match_id is not null and not m.is_within_tolerance then 'variance'
            when m.match_id is not null                     then 'clean'
        end                                                 as verdict,
        m.match_id,
        m.match_tier
    from events e
    left join {{ ref('int_unmatched') }} u on u.event_id = e.event_id
    left join (
        select match_id, match_tier, is_within_tolerance, unnest(internal_event_ids) as event_id
        from {{ ref('int_matches__all') }}
        union all
        select match_id, match_tier, is_within_tolerance, unnest(external_event_ids)
        from {{ ref('int_matches__all') }}
    ) m on m.event_id = e.event_id
),

-- ------------------------------------------------- transaction-grain grading
-- An exception counts as raised if it is open in the FINAL state, or if it
-- was ever raised as a true break on some run date. The second clause matters
-- for timing breaks: a late settlement that eventually arrived is clean at
-- the end, but the queue correctly carried it as "timing_late" for the days
-- it was past the window - and that is the verdict being graded.
raised_asof as (
    select distinct regexp_extract(unnest(event_ids), '([0-9]{9})', 1) as txn_seq
    from {{ ref('int_breaks__run_history') }}
    where is_true_break
),

txn_verdict as (
    select
        v.txn_seq,
        min(v.flow_type)                                    as flow_type,
        bool_or(v.verdict in ('orphan', 'variance'))
            or bool_or(a.txn_seq is not null)               as raised_exception,
        max(v.amount_cents)                                 as amount_cents
    from verdict v
    left join raised_asof a on a.txn_seq = v.txn_seq
    group by v.txn_seq
),

txn_graded as (
    select
        v.txn_seq,
        v.flow_type,
        coalesce(t.break_type, 'no_injection')              as break_type,
        coalesce(t.truth_is_true_break, false)              as truth_is_true_break,
        v.raised_exception,
        v.amount_cents,
        case
            when coalesce(t.truth_is_true_break, false) and v.raised_exception       then 'TP'
            when coalesce(t.truth_is_true_break, false) and not v.raised_exception   then 'FN'
            when not coalesce(t.truth_is_true_break, false) and v.raised_exception   then 'FP'
            else 'TN'
        end                                                 as outcome
    from txn_verdict v
    left join truth t on t.txn_seq = v.txn_seq
),

by_break_type as (
    select
        'transaction'                                       as grain,
        break_type                                          as subject,
        flow_type,
        count(*)                                            as n,
        count(*) filter (where outcome = 'TP')              as tp,
        count(*) filter (where outcome = 'FN')              as fn,
        count(*) filter (where outcome = 'FP')              as fp,
        count(*) filter (where outcome = 'TN')              as tn,
        sum(amount_cents) filter (where outcome = 'FN')     as missed_exposure_cents,
        sum(amount_cents) filter (where outcome = 'FP')     as false_alarm_cents
    from txn_graded
    group by all
),

-- ------------------------------------------------------- match-grain grading
match_graded as (
    select
        m.match_id,
        m.match_tier,
        m.match_rule,
        m.flow_type,
        abs(m.internal_amount_cents)                        as amount_cents,
        -- a correct match pairs records from exactly one transaction
        count(distinct v.txn_seq) = 1                       as is_correct_pair
    from {{ ref('int_matches__all') }} m
    join verdict v on v.match_id = m.match_id
    group by all
),

by_tier as (
    select
        'match'                                             as grain,
        'tier_' || match_tier || '_' || match_rule          as subject,
        flow_type,
        count(*)                                            as n,
        count(*) filter (where is_correct_pair)             as tp,
        0                                                   as fn,
        count(*) filter (where not is_correct_pair)         as fp,
        0                                                   as tn,
        0                                                   as missed_exposure_cents,
        sum(amount_cents) filter (where not is_correct_pair) as false_alarm_cents
    from match_graded
    group by all
),

unioned as (
    select * from by_break_type
    union all
    select * from by_tier
)

select
    grain,
    subject,
    flow_type,
    n,
    tp, fn, fp, tn,
    round(tp / nullif(tp + fp, 0), 4)                       as precision,
    round(tp / nullif(tp + fn, 0), 4)                       as recall,
    round(2.0 * tp / nullif(2 * tp + fp + fn, 0), 4)        as f1,
    coalesce(missed_exposure_cents, 0)                      as missed_exposure_cents,
    coalesce(false_alarm_cents, 0)                          as false_alarm_cents
from unioned
order by grain, flow_type, subject
