select
    customer_id,
    first_name,
    last_name,
    {{ audit_columns() }}
from {{ ref('customers') }}
