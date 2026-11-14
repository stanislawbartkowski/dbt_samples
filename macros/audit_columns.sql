{#- A small helper that every model calls. Any edit between {% macro %} and
    {% endmacro %}, even a Jinja comment, marks every model that calls it as
    state:modified.macros. Edits outside the block, like this comment, don't. -#}
{% macro audit_columns() -%}
    current_timestamp as _loaded_at
{%- endmacro %}
