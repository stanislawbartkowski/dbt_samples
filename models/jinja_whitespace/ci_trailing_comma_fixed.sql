{#- FIXED: filter the list first, then loop. `loop.last` now matches the last emitted column. -#}
{%- set columns = ['customer_id', 'first_name', 'last_name'] -%}
{%- if target.name == 'ci' -%}
    {#- PII columns are not exposed in CI -#}
    {%- set columns = columns | reject('equalto', 'last_name') | list -%}
{%- endif %}

select
{%- for col in columns %}
    {{ col }}{{ "," if not loop.last }}
{%- endfor %}
from {{ ref('customers') }}
