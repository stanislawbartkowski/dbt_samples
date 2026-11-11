{#
  Compares the columns of the table in the database with the columns declared
  in the model's YAML. Returns one row per difference.

  An enforced contract only checks the model's SQL against the YAML, before the
  table is built. On an incremental run, on_schema_change: append_new_columns
  can leave the existing table out of sync with the YAML (for example, it never
  changes a column's type), and nothing checks the table afterwards. This test
  does.
#}
{% test matches_contract(model) %}

{#- graph is empty while dbt-core parses the project, so look up the model only at run time -#}
{%- set declared = {} -%}
{%- set actual = {} -%}
{%- if execute -%}
  {%- set node = graph.nodes.values()
        | selectattr('resource_type', 'equalto', 'model')
        | selectattr('alias', 'equalto', model.identifier)
        | first -%}
  {%- for col in node.columns.values() -%}
    {%- do declared.update({col.name | lower: (col.data_type or '') | lower | replace(' ', '')}) -%}
  {%- endfor -%}
  {%- for col in adapter.get_columns_in_relation(model) -%}
    {%- do actual.update({col.name | lower: col.data_type | lower | replace(' ', '')}) -%}
  {%- endfor -%}
{%- endif -%}

{%- set problems = [] -%}
{%- for name, data_type in declared.items() -%}
  {%- if name not in actual -%}
    {%- do problems.append((name, data_type, 'missing', 'column missing from table')) -%}
  {%- elif actual[name] != data_type -%}
    {%- do problems.append((name, data_type, actual[name], 'data type mismatch')) -%}
  {%- endif -%}
{%- endfor -%}
{%- for name, data_type in actual.items() if name not in declared -%}
  {%- do problems.append((name, 'missing', data_type, 'column not in contract')) -%}
{%- endfor -%}

{%- if problems %}
{%- for p in problems %}
select '{{ p[0] }}' as column_name, '{{ p[1] }}' as contract_type, '{{ p[2] }}' as table_type, '{{ p[3] }}' as mismatch_reason
{%- if not loop.last %} union all{% endif %}
{%- endfor %}
{%- else %}
select '' as column_name, '' as contract_type, '' as table_type, '' as mismatch_reason
where 1 = 0
{%- endif %}

{% endtest %}
