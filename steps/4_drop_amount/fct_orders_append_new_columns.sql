select
    order_id,
    customer_id,
    status
from {{ ref('orders') }}
