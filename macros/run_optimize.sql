{# OPTIMIZE a Delta table, optionally clustering it with ZORDER BY. #}
{% macro optimize_sql(relation, zorder_fields) %}
  optimize {{ relation }}
  {% if zorder_fields | length > 0 %}
  zorder by ({{ zorder_fields | join(', ') }})
  {% endif %}
{% endmacro %}

{# BROKEN: run_query() fetches OPTIMIZE's metrics row, and dbt v2 rejects it. #}
{% macro run_optimize_naive(relation, zorder_fields=[]) %}
  {% do run_query(optimize_sql(relation, zorder_fields)) %}
{% endmacro %}

{# FIXED: only the call changes; statement() with fetch_result=False skips the result set. #}
{% macro run_optimize_safe(relation, zorder_fields=[]) %}
  {% call statement('run_optimize_safe', fetch_result=False) %}
    {{ optimize_sql(relation, zorder_fields) }}
  {% endcall %}
{% endmacro %}
