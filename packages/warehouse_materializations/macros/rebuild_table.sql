{# Custom materializations that drop and recreate a table on every run. #}

{# BROKEN: writes its own DDL, so contract.enforced is silently ignored #}
{% materialization rebuild_table_naive, default %}
  {%- set target_relation = this.incorporate(type='table') -%}

  {{ run_hooks(pre_hooks) }}

  {{ adapter.drop_relation(target_relation) }}
  {% call statement('main') -%}
    create table {{ target_relation }} as (
      {{ sql }}
    )
  {%- endcall %}

  {{ run_hooks(post_hooks) }}
  {{ adapter.commit() }}

  {{ return({'relations': [target_relation]}) }}
{% endmaterialization %}

{# FIXED: checks the contract before dropping anything, then builds the DDL with
   get_create_table_as_sql, which creates the table from the contract's columns #}
{% materialization rebuild_table, default %}
  {%- set target_relation = this.incorporate(type='table') -%}

  {% if config.get('contract').enforced %}
    {% do get_assert_columns_equivalent(sql) %}
  {% endif %}

  {{ run_hooks(pre_hooks) }}

  {{ adapter.drop_relation(target_relation) }}
  {% call statement('main') -%}
    {{ get_create_table_as_sql(False, target_relation, sql) }}
  {%- endcall %}

  {{ run_hooks(post_hooks) }}
  {{ adapter.commit() }}

  {{ return({'relations': [target_relation]}) }}
{% endmaterialization %}
