{{ config(post_hook="{{ comment_with_ids_append(this) }}") }}

select * from {{ ref('customers') }}
