# dbt_utils_demo: contracts on custom materializations

This branch shows that `contract: {enforced: true}` is silently ignored on a custom materialization that writes its own DDL, and how to make a custom materialization enforce the contract.

This branch uses the same dbt v2, Postgres and uv setup as [`concat_macro_overrides`](https://github.com/stanislawbartkowski/dbt_samples/tree/concat_macro_overrides), without the `concat` override. dbt-core 1.x runs through `uvx`; nothing extra is installed in the project. See [Setup](#setup) below.

## The problem

> "We moved a model from `materialized: table` to the custom materialization in our internal package. The model logic didn't change, but its contract stopped being enforced. A type change that used to fail the build now goes straight to the warehouse."

`contract.enforced` is not checked by a generic wrapper around every materialization. The check is a macro, `get_assert_columns_equivalent(sql)`, which compares the columns the model's SQL returns with the columns declared in YAML: their names, data types and number. In dbt-core and dbt 2, it is called from the DDL macros the built-in materializations use:

- `create_table_as`, used by `table` and `incremental`. On Postgres, it also builds the table from the contract's columns and constraints (`postgres__create_table_as`).
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
      contract: {enforced: true}
    columns: &contract_columns
      - name: customer_id
        data_type: bigint
      - name: first_name
        data_type: text
      - name: last_name
        data_type: text

  - name: customers_contract_rebuild_table_naive
    config:
      materialized: rebuild_table_naive
      contract: {enforced: true}
    columns: *contract_columns

  - name: customers_contract_rebuild_table
    config:
      materialized: rebuild_table
      contract: {enforced: true}
    columns: *contract_columns
```

To break the contract on purpose, the models read the `break_contract` variable. With `--vars '{break_contract: true}'`, they return `customer_id` as `text` instead of `bigint`:

```sql
select
    {% if var('break_contract', false) -%}
    cast(customer_id as text) as customer_id,
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
| `customers_contract_rebuild_table_naive` | `rebuild_table_naive` | succeeds | **succeeds, silently** | **`text`** |
| `customers_contract_rebuild_table` | `rebuild_table` | succeeds | **fails:** `data type mismatch` | `bigint` (old table kept) |

The results are the same on dbt 2.0.9 and dbt-core 1.11.16. The failing models report:

```
This model has an enforced contract that failed.
| column_name | definition_type   | contract_type | mismatch_reason    |
| customer_id | character varying | bigint        | data type mismatch |
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
dbt show --inline "select table_name, data_type from information_schema.columns
  where table_schema = '{{ target.schema }}' and table_name like 'customers_contract%'
    and column_name = 'customer_id' order by table_name"
```

```
│ table_name                             ┆ data_type │
│ customers_contract_rebuild_table       ┆ bigint    │
│ customers_contract_rebuild_table_naive ┆ text      │
│ customers_contract_table               ┆ bigint    │
```

The naive table now has `customer_id` as `text`, even though its contract says `bigint`. Run `dbt build` again to restore it.

### Reproduce it with dbt-core 1.x

`profiles_core/profiles.yml` uses the same Postgres with the schema `dbt_contracts_core`:

```bash
export DBT_PROFILES_DIR=profiles_core
CORE="uvx --python 3.11 --from dbt-core~=1.11.0 --with dbt-postgres~=1.11.0 dbt"

$CORE deps
$CORE build --target-path target_core
$CORE run --target-path target_core --vars '{break_contract: true}' -s customers_contract_table customers_contract_rebuild_table_naive customers_contract_rebuild_table
# 1 of 3 ERROR creating sql rebuild_table model ...customers_contract_rebuild_table
# 2 of 3 OK created sql rebuild_table_naive model ...customers_contract_rebuild_table_naive
# 3 of 3 ERROR creating sql table model ...customers_contract_table
```

`--target-path target_core` keeps the dbt-core manifest apart from the dbt v2 one in `target/`.

## How the fix works

- **`get_create_table_as_sql` already enforces the contract.** It dispatches to the adapter's `create_table_as`, which calls `get_assert_columns_equivalent(sql)` and builds the table from the contract's columns. Reusing it is the simplest way to get the same enforcement as `table`.
- **Check before you drop.** `get_create_table_as_sql` raises only when the `create` statement is rendered. `rebuild_table` drops the old table first, so on its own it would drop the table and then fail, leaving no table at all. The explicit `get_assert_columns_equivalent(sql)` at the top of the materialization fails before anything changes, so the old table survives. This runs the check twice, which costs one extra metadata query.
- **Writing your own DDL?** Then call `get_assert_columns_equivalent(sql)` yourself when `config.get('contract').enforced` is true. To also enforce constraints such as `not_null`, build the column list with `get_table_columns_and_constraints()`, as `postgres__create_table_as` does.

## Notes

- **Document which materializations enforce contracts.** dbt doesn't warn about a contract that nothing checks. Make it a rule for your internal packages: either a materialization enforces contracts, or its docs say that it doesn't.
- **Commit in custom materializations.** dbt-core runs a materialization's statements in a transaction. Without `{{ adapter.commit() }}`, dbt-core reports `OK` and then rolls the transaction back, so the table never appears. dbt 2.0.9 commits anyway, so the bug only shows up on dbt-core.
- **Seed types differ between engines.** dbt-core 1.11 loads `customer_id` from `seeds/customers.csv` as `integer`, and dbt 2.0.9 loads it as `bigint`. With a `bigint` contract, the correct models failed on dbt-core. `dbt_project.yml` pins the type with `column_types: {customer_id: bigint}`.

## Project layout

| Path | Purpose |
| --- | --- |
| `seeds/customers.csv` | Sample customer data loaded with `dbt seed` (`customer_id` pinned to `bigint` in `dbt_project.yml`) |
| `models/customer_full_names.sql` | View that combines first and last name into `full_name` |
| `packages/warehouse_materializations/macros/rebuild_table.sql` | The custom materializations `rebuild_table_naive` and `rebuild_table` |
| `models/customers_contract.yml` | The same enforced contract on `table`, `rebuild_table_naive` and `rebuild_table` |
| `models/customers_contract_*.sql` | The three models; `--vars '{break_contract: true}'` breaks the contract |
| `packages.yml` | dbt package dependencies (`dbt-labs/dbt_utils` 1.x and the local `warehouse_materializations`) |
| `pyproject.toml` / `uv.lock` | Python environment; pins `dbt==2.0.9` |
| `env_standard` | Environment variables the project needs (see below) |
| `profiles.yml` | dbt v2 connection to a local Postgres (generic `dbt` / `secret` credentials), schema `dbt_contracts` |
| `profiles_core/profiles.yml` | dbt-core 1.x connection, schema `dbt_contracts_core` |

## Prerequisites

- A running Postgres instance (by default `localhost:5432`, database `dbt_edu`)
- [uv](https://docs.astral.sh/uv/getting-started/installation/)

## Setup

1. **Install dbt v2.** It is pinned in `pyproject.toml`:

   ```bash
   uv sync
   uv run dbt --version   # dbt 2.0.9
   ```

2. **Check `profiles.yml`.** It is included and points to a local Postgres with generic credentials. If your database is set up differently, change these settings:

   ```yaml
   dbt_utils_demo:
     target: dev
     outputs:
       dev:
         type: postgres
         host: localhost
         port: 5432
         user: dbt
         password: secret   # dbt v2 requires `password`, not `pass`
         dbname: dbt_edu
         schema: dbt_contracts
         threads: 1
   ```

3. **Install dbt packages:**

   ```bash
   uv run --env-file env_standard dbt deps --profiles-dir .
   ```

## Environment variables

`env_standard` holds the variables dbt needs for this project:

```
DBT_ALLOW_EXPERIMENTAL_ADAPTERS=true
```

dbt v2 treats Postgres as an experimental adapter and refuses to run without this flag. If it is missing, dbt fails with `The 'postgres' adapter is not yet supported`.

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
| `The 'postgres' adapter is not yet supported` | `env_standard` isn't loaded; see [Environment variables](#environment-variables) |
| `missing field 'password'` | Rename `pass:` to `password:` in `profiles.yml` |
| `bigint` / `integer` contract mismatch on a correct model | dbt-core and dbt 2 infer different seed types; pin them with `column_types` (see `dbt_project.yml`) |
| A custom materialization runs `OK` on dbt-core but the table is missing | It never calls `adapter.commit()`; dbt-core rolls the transaction back |
| `Could not find profile named 'dbt_utils_demo'` | Pass `--profiles-dir .` or set `DBT_PROFILES_DIR` |
