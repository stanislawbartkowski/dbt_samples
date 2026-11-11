select
    c.customer_id,
    count(o.order_id) as order_count,
    cast(coalesce(sum(o.amount), 0) as numeric(38, 2)) as order_total
from {{ ref('customers') }} as c
left join {{ ref('stg_orders') }} as o
    on o.customer_id = c.customer_id
group by c.customer_id
