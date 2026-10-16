{#- BROKEN in CI: builds on `dev`, fails on `--target ci`. -#}
{% set columns = ['customer_id', 'first_name', 'last_name'] %}

select
{% for col in columns %}
    {# PII columns are not exposed in CI #}
    {% if not (target.name == 'ci' and col == 'last_name') %}
    {{ col }}{% if not loop.last %},{% endif %}
    {% endif %}
{% endfor %}
from {{ ref('customers') }}
