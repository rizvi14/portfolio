{#
  Normalise a transaction reference for matching.

  Upper-cases, strips everything that is not a letter or digit, and blanks
  common bank prefixes. Also exposes a suffix helper: Fedwire OBI fields get
  truncated by some banks, so the last 12 characters are the part most likely
  to survive - matching on the suffix is what recovers those items.
#}
{% macro normalize_reference(col) -%}
    nullif(
        regexp_replace(upper(coalesce({{ col }}, '')), '[^A-Z0-9]', '', 'g'),
        ''
    )
{%- endmacro %}

{% macro reference_suffix(col, n=12) -%}
    right({{ normalize_reference(col) }}, {{ n }})
{%- endmacro %}
