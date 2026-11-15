{#- dbt run-operation drop_target_schema --target dev
    Drops the target's schema and everything in it, so a demo starts from an
    empty dev schema. -#}
{% macro drop_target_schema() %}
    {% do run_query('drop schema if exists ' ~ target.schema ~ ' cascade') %}
    {{ log('Dropped schema ' ~ target.schema, info=true) }}
{% endmacro %}
