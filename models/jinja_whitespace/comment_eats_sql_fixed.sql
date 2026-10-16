{#- FIXED: strip only on the left of the tag, so the newline that ends the comment survives. -#}
select
    customer_id,
    first_name -- optional columns below
    {%- if var('include_last_name', true) %}
    , last_name
    {%- endif %}
from {{ ref('customers') }}
