-- depends_on: {{ ref('scratch_naive') }}
{{ cleanup_scratch_naive() }}

select * from {{ ref('customers') }}
