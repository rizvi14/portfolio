-- The bank reconciliation must foot, every run, every rail.
--
-- Balance per bank, plus every named reconciling item, equals balance per
-- books. There is no plug. If this fails, the close package is not a package -
-- it is a number with a footnote, and the footnote is the part that gets
-- signed.
--
-- The threshold is a var rather than a literal zero because a production build
-- ties out across currencies and a rounding cent is not a control failure.
-- Here the bridge is exact and the tolerance is never consumed, which is the
-- desirable state: the allowance exists so that a real rounding difference
-- does not stop the close, not so that a real difference can hide under it.
-- If this test ever starts passing NEAR the threshold rather than at zero,
-- that is the signal to go looking, not to raise the number.

select
    run_date,
    flow_type,
    bank_balance_cents,
    gl_balance_cents,
    difference_cents,
    unexplained_difference_cents,
    {{ var('gl_tieout_tolerance_cents') }} as tolerance_cents
from {{ ref('fct_gl_tieout') }}
where abs(unexplained_difference_cents) > {{ var('gl_tieout_tolerance_cents') }}
