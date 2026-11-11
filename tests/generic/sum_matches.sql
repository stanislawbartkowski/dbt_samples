{#
  Fails when the column doesn't add up to the same total as a column in
  another model. A contract that passes checks the column names and types;
  this test checks the values, so it catches rounding that the contract misses.
#}
{% test sum_matches(model, column_name, compare_model, compare_column) %}

with model_total as (
    select sum({{ column_name }}) as total from {{ model }}
),

compare_total as (
    select sum({{ compare_column }}) as total from {{ compare_model }}
)

select
    model_total.total as model_total,
    compare_total.total as compare_total
from model_total
cross join compare_total
where model_total.total <> compare_total.total

{% endtest %}
