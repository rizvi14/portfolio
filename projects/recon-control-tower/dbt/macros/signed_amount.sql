{#
  Convert a (magnitude, direction) pair into a signed amount.

  Sign convention used everywhere in this project: positive = money INTO the
  partner-bank account (a credit to us), negative = money OUT. The bank
  statement already arrives signed this way; the ledger stores magnitude plus
  direction, so this is the one place that convention is applied.
#}
{% macro signed_amount(amount_col, direction_col) -%}
    case
        when lower({{ direction_col }}) = 'credit' then {{ amount_col }}
        when lower({{ direction_col }}) = 'debit'  then -1 * {{ amount_col }}
    end
{%- endmacro %}
