{{ config(materialized="table" if target.name == "prod" else "view") }}

select
    order_id,
    customer_id,
    amount,
    {{ audit_columns() }}
from {{ ref('stg_orders') }}
