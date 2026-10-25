{#- All four macros return one row per day of September 2020, in a column named date_day.
    They differ only in how they deal with dbt.date_spine, which dbt-core added in 1.7. -#}

{#- BROKEN on dbt-core 1.6: no guard. The project fails to parse with "'date_spine' is undefined". -#}
{% macro days_in_september_naive() %}
  {{ dbt.date_spine("day", "cast('2020-09-01' as date)", "cast('2020-10-01' as date)") }}
{% endmacro %}


{#- BROKEN on dbt 2: the guard from the dbt docs. dbt 2.0.9's `dbt.get()` returns none for every
    macro, so this raises even though dbt.date_spine exists. Works on dbt-core. -#}
{% macro days_in_september_docs_guard() %}
  {% if not dbt.get('date_spine') %}
    {{ exceptions.raise_compiler_error("calendar_utils: expected to find the dbt.date_spine macro, but it could not be found") }}
  {% endif %}
  {{ dbt.date_spine("day", "cast('2020-09-01' as date)", "cast('2020-10-01' as date)") }}
{% endmacro %}


{#- FIXED, hard requirement: the only change from days_in_september_docs_guard is the check.
    `is defined` works on dbt-core and dbt 2. -#}
{% macro days_in_september_safe() %}
  {% if dbt.date_spine is not defined %}
    {{ exceptions.raise_compiler_error("calendar_utils: expected to find the dbt.date_spine macro, but it could not be found") }}
  {% endif %}
  {{ dbt.date_spine("day", "cast('2020-09-01' as date)", "cast('2020-10-01' as date)") }}
{% endmacro %}


{#- FIXED, soft dependency: use dbt.date_spine when it exists, otherwise build the days by hand. -#}
{% macro days_in_september() %}
  {% if dbt.date_spine is defined %}
    {{ dbt.date_spine("day", "cast('2020-09-01' as date)", "cast('2020-10-01' as date)") }}
  {% else %}
    {% for i in range(30) %}
      select {{ dbt.dateadd("day", i, "cast('2020-09-01' as date)") }} as date_day
      {% if not loop.last %}union all{% endif %}
    {% endfor %}
  {% endif %}
{% endmacro %}
