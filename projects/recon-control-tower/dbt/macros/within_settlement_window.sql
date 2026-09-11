{#
  Is an external date within the expected settlement window of an internal one?

  Each rail settles on its own clock - ACH T+1/T+2, card T+2/T+3, wire same
  day. A record landing inside the window is timing, not a break, and an item
  is only "matured" (eligible for match-rate measurement) once the window has
  elapsed. Measuring match rate on items that have not had time to settle is
  the most common self-inflicted recon wound.
#}
{% macro settlement_window_days(flow_col) -%}
    case {{ flow_col }}
        when 'ach'  then {{ var('window_days_ach') }}
        when 'card' then {{ var('window_days_card') }}
        when 'wire' then {{ var('window_days_wire') }}
        else 2
    end
{%- endmacro %}

{% macro within_settlement_window(internal_date, external_date, flow_col) -%}
    ({{ external_date }} >= {{ internal_date }}
     and {{ external_date }} <= {{ internal_date }} + interval (({{ settlement_window_days(flow_col) }}) + 3) day)
{%- endmacro %}
