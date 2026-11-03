select
    {% if var('break_contract', false) -%}
    cast(customer_id as text) as customer_id,
    {%- else -%}
    customer_id,
    {%- endif %}
    first_name,
    last_name
from {{ ref('customers') }}
