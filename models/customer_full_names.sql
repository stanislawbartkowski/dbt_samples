select
    customer_id,
    first_name,
    last_name,
    {{ dbt.concat(['first_name', 'last_name']) }} as full_name
from {{ ref('customers') }}
