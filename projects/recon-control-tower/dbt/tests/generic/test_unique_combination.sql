{#
  Composite-key uniqueness without pulling in dbt_utils for one test.
  Usage in schema.yml:
      data_tests:
        - unique_combination:
            arguments:
              combination: [rate_date, currency]
#}
{% test unique_combination(model, combination) %}
select
    {{ combination | join(', ') }},
    count(*) as n
from {{ model }}
group by {{ combination | join(', ') }}
having count(*) > 1
{% endtest %}
