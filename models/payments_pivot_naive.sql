{#- BROKEN: during parse, run_query() doesn't run the query.
    dbt-core 1.x returns None, so `results.columns` fails.
    dbt v2 returns an empty value, so the list is empty and the check below fails. -#}
{% set payment_method_query %}
select distinct payment_method from {{ ref('payments') }} order by 1
{% endset %}

{% set results = run_query(payment_method_query) %}
{% set payment_methods = results.columns[0].values() %}
{% if payment_methods | length == 0 %}
  {{ exceptions.raise_compiler_error("payments has no payment methods") }}
{% endif %}

select
    customer_id,
    {% for payment_method in payment_methods %}
    sum(case when payment_method = '{{ payment_method }}' then amount else 0 end) as {{ payment_method }}_amount{{ "," if not loop.last }}
    {% endfor %}
from {{ ref('payments') }}
group by 1
