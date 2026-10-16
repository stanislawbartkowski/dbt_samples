{#- Helper: `dbt run-operation scratch_counts` prints how many rows each scratch table holds. -#}
{% macro scratch_counts() %}
  {% for name in ['scratch_naive', 'scratch_safe'] %}
    {% set n = run_query("select count(*) from " ~ ref(name)).columns[0].values()[0] %}
    {{ log(name ~ ": " ~ n ~ " rows", info=true) }}
  {% endfor %}
{% endmacro %}
