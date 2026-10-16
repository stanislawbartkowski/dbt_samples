{# Overrides dbt.concat on Postgres: joins fields with ' - ' instead of no separator. #}
{% macro postgres__concat(fields) -%}
    {{ fields | join(" || ' - ' || ") }}
{%- endmacro %}
