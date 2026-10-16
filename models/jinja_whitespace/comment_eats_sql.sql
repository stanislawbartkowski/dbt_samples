{#- BROKEN (silently): `-%}` eats the newline after the `--` comment,
    so `, last_name` ends up inside the comment. The model builds, but last_name is missing. -#}
select
    customer_id,
    first_name -- optional columns below
    {%- if var('include_last_name', true) -%}
    , last_name
    {%- endif %}
from {{ ref('customers') }}
