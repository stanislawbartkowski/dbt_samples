-- Dev builds run on a sample that leaves out the one large order.
-- Pass --vars '{prod_data: true}' to build on all orders, like prod.
select
    order_id,
    customer_id,
    amount
from {{ ref('orders') }}
{%- if not var('prod_data') %}
where amount < 1000000
{%- endif %}
