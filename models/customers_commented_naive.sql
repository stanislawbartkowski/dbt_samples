{{ config(post_hook="{{ comment_with_ids_naive(this) }}") }}

select * from {{ ref('customers') }}
