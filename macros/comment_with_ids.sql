{# Post-hooks that record which customer_ids a view returned, as a property of the view. #}

{# BROKEN: the set inside the loop binds a new found_ids that disappears at endfor #}
{% macro comment_with_ids_naive(relation) %}
  {% if execute %}
    {% set results = run_query("select customer_id from " ~ relation ~ " order by customer_id") %}
    {% set found_ids = [] %}
    {% for row in results %}
      {% set found_ids = found_ids + [row['customer_id']] %}
    {% endfor %}
    alter view {{ relation }} set tblproperties ('customer_ids' = '{{ found_ids | join(", ") }}')
  {% endif %}
{% endmacro %}

{# FIXED: a namespace attribute set inside the loop is still visible after it #}
{% macro comment_with_ids(relation) %}
  {% if execute %}
    {% set results = run_query("select customer_id from " ~ relation ~ " order by customer_id") %}
    {% set ns = namespace(found_ids=[]) %}
    {% for row in results %}
      {% set ns.found_ids = ns.found_ids + [row['customer_id']] %}
    {% endfor %}
    alter view {{ relation }} set tblproperties ('customer_ids' = '{{ ns.found_ids | join(", ") }}')
  {% endif %}
{% endmacro %}

{# ALSO FIXED: append mutates the list in place instead of rebinding the name #}
{% macro comment_with_ids_append(relation) %}
  {% if execute %}
    {% set results = run_query("select customer_id from " ~ relation ~ " order by customer_id") %}
    {% set found_ids = [] %}
    {% for row in results %}
      {% do found_ids.append(row['customer_id']) %}
    {% endfor %}
    alter view {{ relation }} set tblproperties ('customer_ids' = '{{ found_ids | join(", ") }}')
  {% endif %}
{% endmacro %}
