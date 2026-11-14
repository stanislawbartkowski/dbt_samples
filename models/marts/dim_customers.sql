select
    customer_id,
    first_name || ' ' || last_name as full_name,
    {{ audit_columns() }}
from {{ ref('stg_customers') }}
