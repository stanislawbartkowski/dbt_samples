{#- BROKEN: run_query() returns None while dbt parses the project,
    so `results.columns` fails on a full parse. -#}
{% set payment_method_query %}
select distinct payment_method from {{ ref('payments') }} order by 1
{% endset %}

{% set results = run_query(payment_method_query) %}
{% set payment_methods = results.columns[0].values() %}

select
    customer_id,
    {% for payment_method in payment_methods %}
    sum(case when payment_method = '{{ payment_method }}' then amount else 0 end) as {{ payment_method }}_amount{{ "," if not loop.last }}
    {% endfor %}
from {{ ref('payments') }}
group by 1
