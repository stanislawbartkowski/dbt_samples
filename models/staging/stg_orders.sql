select
    order_id,
    customer_id,
    amount,
    {{ audit_columns() }}
from {{ ref('orders') }}
