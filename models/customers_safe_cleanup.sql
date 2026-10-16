-- depends_on: {{ ref('scratch_safe') }}
{{ cleanup_scratch_safe() }}

select * from {{ ref('customers') }}
