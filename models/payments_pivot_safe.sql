{#- FIXED: read the result only when execute is True. The only change from
    payments_pivot_naive is the {% if execute %} block. -#}
{% set payment_method_query %}
select distinct payment_method from {{ ref('payments') }} order by 1
{% endset %}

{% set results = run_query(payment_method_query) %}
{{ log("payments_pivot_safe: execute=" ~ execute, info=true) }}
{% if execute %}
  {% set payment_methods = results.columns[0].values() %}
{% else %}
  {% set payment_methods = [] %}
{% endif %}

select
    customer_id,
    {% for payment_method in payment_methods %}
    sum(case when payment_method = '{{ payment_method }}' then amount else 0 end) as {{ payment_method }}_amount{{ "," if not loop.last }}
    {% endfor %}
from {{ ref('payments') }}
group by 1
