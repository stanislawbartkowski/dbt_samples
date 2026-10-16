{#- FIXED: strip only before each tag; the newline after `select` and before `from` remains. -#}
{%- set columns = ['customer_id', 'first_name', 'last_name'] -%}
select
{%- for col in columns %}
    {{ col }}{{ "," if not loop.last }}
{%- endfor %}
from {{ ref('customers') }}
