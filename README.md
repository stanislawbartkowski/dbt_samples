# dbt_utils_demo: contracts on custom materializations

This branch shows that `contract: {enforced: true}` is silently ignored on a custom materialization that writes its own DDL, and how to make a custom materialization enforce the contract.

This branch uses the same dbt v2 and uv setup as [`concat_macro_overrides`](https://github.com/stanislawbartkowski/dbt_samples/tree/concat_macro_overrides), but on Spark (through Spark Connect) with Delta Lake instead of Postgres, and without the `concat` override. dbt-core 1.x runs through `uvx`; nothing extra is installed in the project. See [Setup](#setup) below.

## The problem

> "We moved a model from `materialized: table` to the custom materialization in our internal package. The model logic didn't change, but its contract stopped being enforced. A type change that used to fail the build now goes straight to the warehouse."

`contract.enforced` is not checked by a generic wrapper around every materialization. The check is a macro, `get_assert_columns_equivalent(sql)`, which compares the columns the model's SQL returns with the columns declared in YAML: their names, data types and number. In dbt-core and dbt 2, it is called from the DDL macros the built-in materializations use:

- `create_table_as`, used by `table` and `incremental`. On Spark, `spark__create_table_as` also reorders the selected columns to match the contract.
- `create_view_as`, used by `view`.

A custom materialization that writes its own `create table ... as` never calls these macros, so nothing checks the contract. dbt doesn't raise an error or a warning. The model builds, and `contract.enforced: true` in the YAML looks like protection that isn't there.

## The example

`packages/warehouse_materializations` is a small local package (installed from `packages.yml` with `local:`), like an internal package your team would share. It has two custom materializations that drop and recreate a table on every run (`packages/warehouse_materializations/macros/rebuild_table.sql`):

```sql
{# BROKEN: writes its own DDL, so contract.enforced is silently ignored #}
{% materialization rebuild_table_naive, default %}
  ...
  {% call statement('main') -%}
    create table {{ target_relation }} as (
      {{ sql }}
    )
  {%- endcall %}
  ...
{% endmaterialization %}

{# FIXED: checks the contract before dropping anything, then builds the DDL with
   get_create_table_as_sql, which creates the table from the contract's columns #}
{% materialization rebuild_table, default %}
  ...
  {% if config.get('contract').enforced %}
    {% do get_assert_columns_equivalent(sql) %}
  {% endif %}
  ...
  {% call statement('main') -%}
    {{ get_create_table_as_sql(False, target_relation, sql) }}
  {%- endcall %}
  ...
{% endmaterialization %}
```

Three models have the same SQL and the same enforced contract, and differ only in their materialization (`models/customers_contract.yml`):

```yaml
models:
  - name: customers_contract_table
    config:
      materialized: table
      file_format: delta
      contract: {enforced: true}
    columns: &contract_columns
      - name: customer_id
        data_type: bigint
      - name: first_name
        data_type: string
      - name: last_name
        data_type: string

  - name: customers_contract_rebuild_table_naive
    config:
      materialized: rebuild_table_naive
      file_format: delta
      contract: {enforced: true}
    columns: *contract_columns

  - name: customers_contract_rebuild_table
    config:
      materialized: rebuild_table
      file_format: delta
      contract: {enforced: true}
    columns: *contract_columns
```

To break the contract on purpose, the models read the `break_contract` variable. With `--vars '{break_contract: true}'`, they return `customer_id` as `string` instead of `bigint`:

```sql
select
    {% if var('break_contract', false) -%}
    cast(customer_id as string) as customer_id,
    {%- else -%}
    customer_id,
    {%- endif %}
    first_name,
    last_name
from {{ ref('customers') }}
```

### What each materialization does

| Model | Materialization | Contract kept | Contract broken (`break_contract: true`) | `customer_id` in the database afterwards |
| --- | --- | --- | --- | --- |
| `customers_contract_table` | `table` | succeeds | **fails:** `data type mismatch` | `bigint` (old table kept) |
| `customers_contract_rebuild_table_naive` | `rebuild_table_naive` | succeeds | **succeeds, silently** | **`string`** |
| `customers_contract_rebuild_table` | `rebuild_table` | succeeds | **fails:** `data type mismatch` | `bigint` (old table kept) |

The results are the same on dbt 2.0.9 and dbt-core 1.11.16 with dbt-spark 1.11.0, tested on Spark 4.2.0 with Delta Lake 4.4.1. The failing models report:

```
This model has an enforced contract that failed.
| column_name | definition_type | contract_type | mismatch_reason    |
| customer_id | string          | bigint        | data type mismatch |
```

### Reproduce it with dbt 2.0.9

```bash
source .venv/bin/activate
set -a; source env_standard; set +a
export DBT_PROFILES_DIR=.

dbt deps
dbt build    # everything succeeds: the contracts match

# break the contract: 2 errors, but rebuild_table_naive succeeds
dbt run --vars '{break_contract: true}' -s customers_contract_table customers_contract_rebuild_table_naive customers_contract_rebuild_table
```

```
    Failed model dbt_contracts.customers_contract_table (table) [1 of 3 in 0.02s]
 Succeeded model dbt_contracts.customers_contract_rebuild_table_naive (rebuild_table_naive) [2 of 3 in 0.04s]
    Failed model dbt_contracts.customers_contract_rebuild_table (rebuild_table) [3 of 3 in 0.04s]
```

Check the column types in the database:

```bash
for m in customers_contract_table customers_contract_rebuild_table_naive customers_contract_rebuild_table; do
  echo "$m: $(dbt show --limit -1 --inline "describe {{ target.schema }}.$m" | grep customer_id)"
done
```

```
customers_contract_table: │ customer_id ┆ bigint    ┆         │
customers_contract_rebuild_table_naive: │ customer_id ┆ string    ┆         │
customers_contract_rebuild_table: │ customer_id ┆ bigint    ┆         │
```

`--limit -1` matters: by default `dbt show` adds `limit 10` to the query, and Spark rejects a `limit` after `describe`.

The naive table now has `customer_id` as `string`, even though its contract says `bigint`. Run `dbt build` again to restore it.

### Reproduce it with dbt-core 1.x

dbt-spark has no Spark Connect method. Its `session` method uses PySpark, which connects to Spark Connect when `SPARK_REMOTE` is set. `profiles_core/profiles.yml` uses that, with the schema `dbt_contracts_core`:

```bash
export SPARK_REMOTE=sc://localhost:15002
export DBT_PROFILES_DIR=profiles_core
CORE="uvx --python 3.12 --from dbt-core~=1.11.0 --with dbt-spark[session]~=1.10 --with pyspark[connect]==4.2.0 dbt"

$CORE deps
$CORE build --target-path target_core
$CORE run --target-path target_core --vars '{break_contract: true}' -s customers_contract_table customers_contract_rebuild_table_naive customers_contract_rebuild_table
# 1 of 3 ERROR creating sql rebuild_table model ...customers_contract_rebuild_table
# 2 of 3 OK created sql rebuild_table_naive model ...customers_contract_rebuild_table_naive
# 3 of 3 ERROR creating sql table model ...customers_contract_table
```

`--target-path target_core` keeps the dbt-core manifest apart from the dbt v2 one in `target/`.

## How the fix works

- **`get_create_table_as_sql` already enforces the contract.** It dispatches to the adapter's `create_table_as`, which calls `get_assert_columns_equivalent(sql)` and selects the columns in the contract's order. Reusing it is the simplest way to get the same enforcement as `table`.
- **Check before you drop.** `get_create_table_as_sql` raises only when the `create` statement is rendered. `rebuild_table` drops the old table first, so on its own it would drop the table and then fail, leaving no table at all. The explicit `get_assert_columns_equivalent(sql)` at the top of the materialization fails before anything changes, so the old table survives. This runs the check twice, which costs one extra metadata query.
- **Writing your own DDL?** Then call `get_assert_columns_equivalent(sql)` yourself when `config.get('contract').enforced` is true. Constraints such as `not_null` are a separate step on Spark: the built-in `table` materialization calls `persist_constraints(target_relation, model)` after the `create`, and it only applies them to Delta tables. Call it in your materialization too if your contracts have constraints.

## Notes

- **Document which materializations enforce contracts.** dbt doesn't warn about a contract that nothing checks. Make it a rule for your internal packages: either a materialization enforces contracts, or its docs say that it doesn't.
- **Delta keeps the old table.** Without `file_format: delta` (or `iceberg`), the built-in Spark `table` materialization drops the old table before it runs the `create`, so a failed contract check leaves no table at all. With Delta, it uses `create or replace table` and the old table survives. The models here use Delta so that `table` and `rebuild_table` behave the same.
- **Commit in custom materializations.** Spark has no transactions, so `{{ adapter.commit() }}` does nothing here. Keep it anyway: on adapters with transactions, such as Postgres, dbt-core reports `OK` without it and then rolls the transaction back, so the table never appears.
- **Pin seed types.** On Postgres, dbt-core 1.11 loads `customer_id` from `seeds/customers.csv` as `integer` and dbt 2.0.9 as `bigint`, which broke a `bigint` contract on the correct models. `dbt_project.yml` pins the type with `column_types: {customer_id: bigint}`, so the contract doesn't depend on type inference.

## Project layout

| Path | Purpose |
| --- | --- |
| `seeds/customers.csv` | Sample customer data loaded with `dbt seed` (`customer_id` pinned to `bigint` in `dbt_project.yml`) |
| `models/customer_full_names.sql` | View that combines first and last name into `full_name` |
| `packages/warehouse_materializations/macros/rebuild_table.sql` | The custom materializations `rebuild_table_naive` and `rebuild_table` |
| `models/customers_contract.yml` | The same enforced contract on `table`, `rebuild_table_naive` and `rebuild_table`, all Delta |
| `models/customers_contract_*.sql` | The three models; `--vars '{break_contract: true}'` breaks the contract |
| `packages.yml` | dbt package dependencies (`dbt-labs/dbt_utils` 1.x and the local `warehouse_materializations`) |
| `pyproject.toml` / `uv.lock` | Python environment; pins `dbt==2.0.9` |
| `env_standard` | Environment variables the project needs (see below) |
| `profiles.yml` | dbt v2 connection to Spark Connect on `localhost:15002`, schema `dbt_contracts` |
| `profiles_core/profiles.yml` | dbt-core 1.x connection through PySpark, schema `dbt_contracts_core` |

## Prerequisites

- A Spark Connect server with Delta Lake on `localhost:15002`. This branch was tested with Spark 4.2.0 and Delta Lake 4.4.1; the Delta version must match the Spark version. For example:

  ```bash
  $SPARK_HOME/sbin/start-connect-server.sh \
    --packages org.apache.spark:spark-connect_2.13:4.2.0,io.delta:delta-spark_2.13:4.4.1 \
    --conf spark.sql.extensions=io.delta.sql.DeltaSparkSessionExtension \
    --conf spark.sql.catalog.spark_catalog=org.apache.spark.sql.delta.catalog.DeltaCatalog \
    --conf spark.sql.catalogImplementation=hive
  ```

- [uv](https://docs.astral.sh/uv/getting-started/installation/)

## Setup

1. **Install dbt v2.** It is pinned in `pyproject.toml`:

   ```bash
   uv sync
   uv run dbt --version   # dbt 2.0.9
   ```

2. **Check `profiles.yml`.** It is included and points to Spark Connect on `localhost:15002`:

   ```yaml
   dbt_utils_demo:
     outputs:
       dev:
         type: spark
         method: spark-connect
         host: "localhost:15002/;user_id=dbt"
         schema: dbt_contracts
         threads: 1
     target: dev
   ```

   dbt 2.0.9 builds the URL as `sc://<host>:<port>/`, and the Spark Connect client rejects the trailing `/`. Put the port and a user in `host`, as above, and leave out `port`.

3. **Install dbt packages:**

   ```bash
   uv run --env-file env_standard dbt deps --profiles-dir .
   ```

## Environment variables

`env_standard` holds the variables dbt needs for this project:

```
DBT_ALLOW_EXPERIMENTAL_ADAPTERS=true
```

dbt v2 treats Spark as an experimental adapter and refuses to run without this flag. If it is missing, dbt fails with `The 'spark' adapter is not yet supported`.

Load it in one of two ways:

- **Per command**, with uv:

  ```bash
  uv run --env-file env_standard dbt build --profiles-dir .
  ```

- **Once per shell session.** After this, plain `dbt` works without `uv run`:

  ```bash
  source .venv/bin/activate
  set -a; source env_standard; set +a
  dbt build --profiles-dir .
  ```

## Common commands

These examples assume the shell session from above. Otherwise, prefix each one with `uv run --env-file env_standard`.

```bash
dbt deps --profiles-dir .                        # install packages from packages.yml
dbt seed --profiles-dir .                        # load seeds/customers.csv
dbt run --profiles-dir .                         # build models
dbt build --profiles-dir .                       # seed + run + test, in order
dbt show --profiles-dir . -s customer_full_names # preview a model
dbt clean --profiles-dir .                       # remove target/ and dbt_packages/
```

To skip passing `--profiles-dir .` each time, run `export DBT_PROFILES_DIR=.`.

## Troubleshooting

| Error | Fix |
| --- | --- |
| `The 'spark' adapter is not yet supported` | `env_standard` isn't loaded; see [Environment variables](#environment-variables) |
| `the URL path (/) must be empty or have a proper parameter syntax` | Put the port in `host` (`"localhost:15002/;user_id=dbt"`) and remove `port`; see [Setup](#setup) |
| `Syntax error at or near 'limit'` from `dbt show` | Add `--limit -1` when the query is a `show ...` statement |
| `bigint` / `integer` contract mismatch on a correct model | The engines infer seed types differently; pin them with `column_types` (see `dbt_project.yml`) |
| A failed `table` model leaves no table | The model isn't Delta; set `file_format: delta` |
| `Could not find profile named 'dbt_utils_demo'` | Pass `--profiles-dir .` or set `DBT_PROFILES_DIR` |
