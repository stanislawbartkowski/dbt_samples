select
    order_id,
    customer_id,
    cast(amount as double) as amount,
    status
from {{ ref('orders') }}
