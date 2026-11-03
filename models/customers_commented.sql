{{ config(post_hook="{{ comment_with_ids(this) }}") }}

select * from {{ ref('customers') }}
