{{ config(
    materialized='table',
    file_format='delta',
    post_hook="{{ run_optimize_safe(this, ['customer_id']) }}"
) }}

select * from {{ ref('customers') }}
