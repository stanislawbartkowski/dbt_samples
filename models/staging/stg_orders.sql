{#- Ephemeral: no relation of its own, so --defer can never point it at prod.
    Its SQL is inlined into fct_orders as a CTE, from the current code. -#}
{{ config(materialized='ephemeral') }}

select
    order_id,
    customer_id,
    amount
from {{ ref('orders') }}
