{#- BROKEN: `execute` is True whenever dbt compiles with a live connection,
    including `dbt compile`, `dbt docs generate` and `dbt show`. The DELETE fires for all of them. -#}
{% macro cleanup_scratch_naive() %}
  {% if execute %}
    {{ log("cleanup_scratch_naive: DELETE fired during '" ~ flags.WHICH ~ "'", info=true) }}
    {% do run_query("delete from " ~ ref('scratch_naive')) %}
  {% endif %}
{% endmacro %}


{#- FIXED: run the side effect only for the commands that actually materialize models. -#}
{% macro cleanup_scratch_safe() %}
  {% if execute and flags.WHICH in ['run', 'build'] %}
    {{ log("cleanup_scratch_safe: DELETE fired during '" ~ flags.WHICH ~ "'", info=true) }}
    {% call statement('cleanup_scratch_safe', fetch_result=False) %}
      delete from {{ ref('scratch_safe') }}
    {% endcall %}
  {% endif %}
{% endmacro %}
