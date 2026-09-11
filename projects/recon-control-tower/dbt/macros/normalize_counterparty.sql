{#
  Normalise a counterparty display name so that cosmetic differences do not
  defeat attribute matching.

  Upper-case, strip punctuation, collapse whitespace, then drop legal-entity
  suffixes (LLC, INC, CORP ...). This is the same normalisation used in a
  fuzzy dedupe routine elsewhere in this portfolio (career_tracking's
  duplicates.js) - the problem shape is identical.

  It is deliberately NOT the primary key for attribute matching. Names change
  under Notification-of-Change and bank free-text mangling; account identity
  does not. See RCA-004 for the recall difference.
#}
{% macro normalize_counterparty(col) -%}
    nullif(trim(
        regexp_replace(
            regexp_replace(
                regexp_replace(upper(coalesce({{ col }}, '')), '[^A-Z0-9 ]', ' ', 'g'),
                '\b(L L C|LLC|INC|INCORPORATED|CORP|CORPORATION|CO|HOLDINGS|GROUP|PARTNERS|LTD|LABS|DBA)\b',
                '', 'g'
            ),
            '\s+', ' ', 'g'
        )
    ), '')
{%- endmacro %}
