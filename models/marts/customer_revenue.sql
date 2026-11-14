select
    c.customer_id,
    c.full_name,
    coalesce(sum(o.amount), 0) as revenue,
    {{ audit_columns() }}
from {{ ref('dim_customers') }} as c
left join {{ ref('fct_orders') }} as o
    on o.customer_id = c.customer_id
group by c.customer_id, c.full_name
