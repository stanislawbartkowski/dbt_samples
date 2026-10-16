{#- BROKEN: `-` on both sides of every tag strips the spaces SQL needs between tokens:
    `selectcustomer_id,first_name,last_namefrom ...` -#}
{%- set columns = ['customer_id', 'first_name', 'last_name'] -%}
select
    {%- for col in columns -%}
    {{ col }}{{ "," if not loop.last }}
    {%- endfor -%}
from {{ ref('customers') }}
