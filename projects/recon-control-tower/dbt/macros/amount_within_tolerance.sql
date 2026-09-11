{#
  Is the difference between two amounts acceptable?

  Tolerance is the greater of an absolute floor and a relative band, because
  real fee structures are "x bps + y cents": a $5 card transaction and a $50k
  wire cannot share a single number.

  The relative band is PER FLOW, and for wires it is zero. A basis-point band
  scales with principal: on a $100k wire, 25 bps is $250 - seven times the
  $35 correspondent fee it would silently absorb. Wire differences are fixed
  fees and FX rounding, both of which the absolute floor handles. That finding
  came straight out of the evaluation mart (wire_fee_deducted recall was 0.0
  before this change) and is written up in RCA-002.

  Tolerance is for known, small, structural differences. It must never be
  widened to absorb a variance you have not explained.
#}
{% macro tolerance_bps_for(flow_col) -%}
    case {{ flow_col }}
        when 'wire' then {{ var('tolerance_bps_wire') }}
        when 'card' then {{ var('tolerance_bps_card') }}
        else             {{ var('tolerance_bps_ach') }}
    end
{%- endmacro %}

{% macro amount_within_tolerance(a, b, flow_col, abs_cents=none) -%}
    {%- set abs_cents = abs_cents if abs_cents is not none else var('tolerance_abs_cents') -%}
    abs(({{ a }}) - ({{ b }})) <= greatest(
        {{ abs_cents }},
        abs({{ a }}) * ({{ tolerance_bps_for(flow_col) }}) / 10000.0
    )
{%- endmacro %}
