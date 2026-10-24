{{ config(
    materialized='table',
    file_format='delta',
    post_hook="{{ run_optimize_naive(this, ['customer_id']) }}"
) }}

select * from {{ ref('customers') }}
