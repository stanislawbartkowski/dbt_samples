# dbt_utils_demo: `on_schema_change` with enforced contracts

This branch tests which `on_schema_change` values are safe on an incremental model with an enforced contract. It shows that the usual advice is half right:

- **`ignore` and `sync_all_columns` can't drift silently, because dbt rejects them.** Every dbt version with contracts (dbt-core 1.5 to 1.11, and dbt 2.0.9) fails at parse time. This includes leaving `on_schema_change` unset, because the default is `ignore`.
- **The silent drift happens with `append_new_columns`, one of the two values dbt allows.** It never changes the type of an existing column. Change a type in both the SQL and the YAML, and the run succeeds, but the table keeps the old type. Nothing checks the table against the contract afterwards.
- **`fail` is the only value that keeps the table and the contract in sync.** For any other value, add a test that compares the live table with the contract. This branch includes one: `matches_contract`.

This branch uses the same dbt v2 and uv setup as [`concat_macro_overrides`](https://github.com/stanislawbartkowski/dbt_samples/tree/concat_macro_overrides), but on Spark (through Spark Connect) with Delta Lake instead of Postgres. dbt-core 1.x runs through `uvx`; nothing extra is installed in the project. See [Setup](#setup) below.

## The problem

A common explanation of this interaction goes like this:

> A model with an enforced contract and `on_schema_change: ignore` on an incremental materialization silently drifts out of sync with its own YAML contract after a new column is added to the SQL. `sync_all_columns` fails the opposite way: it drops columns that are missing from the new query. Only `append_new_columns` (adds, never silently drops) and `fail` are safe.

Its key point is right: **an enforced contract checks the model's SQL against the YAML, never the table in the database.** On every run, the incremental materialization builds a temporary relation from the SQL, and `get_assert_columns_equivalent` compares that relation's columns with the YAML. After that, `on_schema_change` alone decides what happens to the existing table.

The rest doesn't hold. dbt validates the combination when it parses the project:

```
[error] [InvalidConfig (dbt1005)]: Invalid value for on_schema_change: ignore. Models materialized as incremental with contracts enabled must set on_schema_change to 'append_new_columns' or 'fail'
```

So `ignore` and `sync_all_columns` never reach the warehouse. But `append_new_columns` doesn't keep the table in sync either. It only adds new columns, and it ignores type changes and removed columns.

## The example

Two incremental models have the same SQL and the same enforced contract, and differ only in `on_schema_change` (`models/orders/fct_orders.yml`):

```yaml
models:
  - name: fct_orders_append_new_columns
    config: &incremental
      materialized: incremental
      incremental_strategy: merge
      unique_key: order_id
      file_format: delta
      contract: {enforced: true}
      on_schema_change: append_new_columns
    data_tests: &contract_tests
      - matches_contract
    columns: &contract_columns
      - name: order_id
        data_type: bigint
      - name: customer_id
        data_type: bigint
      - name: amount
        data_type: decimal(10,2)

  - name: fct_orders_fail
    config:
      <<: *incremental
      on_schema_change: fail
    data_tests: *contract_tests
    columns: *contract_columns
```

The model evolves in steps. Each folder in `steps/` holds the SQL and YAML for one step, and the SQL and the contract always change together:

| Step | Change to the SQL and the contract |
| --- | --- |
| `steps/rejected` | Contract from step 1, but with `on_schema_change: ignore` and `sync_all_columns` (YAML only) |
| `steps/1_initial` | `order_id bigint`, `customer_id bigint`, `amount decimal(10,2)` |
| `steps/2_add_status` | Adds `status string` |
| `steps/3_retype_amount` | Changes `amount` to `double` (`cast(amount as double)`) |
| `steps/4_drop_amount` | Removes `amount` |

To apply a step, copy its files over `models/orders/`:

```bash
cp steps/2_add_status/* models/orders/
diff -r steps/1_initial steps/2_add_status   # shows exactly what the step changes
```

`models/orders/` holds step 1 when you check out the branch.

### What each `on_schema_change` value does

Each row starts from the table that the previous step left. `fct_orders_fail` stops at step 2, so its table stays at step 1.

| Step | `ignore` / `sync_all_columns` | `append_new_columns` | `fail` |
| --- | --- | --- | --- |
| rejected | **parse fails:** `Invalid value for on_schema_change` | | |
| 1. initial | | succeeds | succeeds |
| 2. add `status` | | succeeds, adds `status` | **fails:** `schemas ... are out of sync` |
| 3. `amount` → `double` | | **succeeds, silently.** The table keeps `amount decimal(10,2)`. `matches_contract` fails. | **fails** |
| 4. remove `amount` | | **fails** on Spark: `DELTA_MERGE_UNRESOLVED_EXPRESSION` | **fails** |

The results are the same on dbt 2.0.9 and dbt-core 1.11.17 with dbt-spark 1.11.0, tested on Spark 4.2.0 with Delta Lake 4.4.1. The parse error for `ignore` and `sync_all_columns` was also checked on dbt-core 1.5, 1.6, 1.7, 1.8, 1.9 and 1.10.

Step 3 is the silent one. The contract check passes because the SQL and the YAML agree on `double`. Then `append_new_columns` only looks for new columns, so the merge writes the `double` values into the existing `decimal(10,2)` column. After the run, the table and its contract disagree:

```
│ col_name    ┆ data_type     │        contract
│ order_id    ┆ bigint        │        bigint
│ customer_id ┆ bigint        │        bigint
│ amount      ┆ decimal(10,2) │   ≠    double
│ status      ┆ string        │        string
```

Step 4 fails on Spark only because the merge statement uses `update set *` and `insert *`, and Delta can't resolve `amount` in the new query. That's a database error, not a contract check. On adapters that build the merge from the target's columns, the run can succeed, and the table keeps `amount` (empty for new rows), which the contract no longer declares.

### Reproduce it with dbt 2.0.9

```bash
source .venv/bin/activate
set -a; source env_standard; set +a
export DBT_PROFILES_DIR=.
dbt deps

# dbt rejects ignore and sync_all_columns: 2 errors
cp steps/rejected/* models/orders/
dbt parse

# step 1: everything succeeds and both tests pass
cp steps/1_initial/* models/orders/
dbt build --full-refresh

# step 2: append_new_columns adds status; fail fails
cp steps/2_add_status/* models/orders/
dbt build -s path:models/orders

# step 3: append_new_columns succeeds, but matches_contract fails
cp steps/3_retype_amount/* models/orders/
dbt build -s path:models/orders
```

```
    Failed model dbt_schema_change.fct_orders_fail (incremental) [1 of 4 in 0.28s]
   Skipped test  matches_contract_fct_orders_fail_ (models/orders/fct_orders.yml:14:9) [3 of 4]
 Succeeded model dbt_schema_change.fct_orders_append_new_columns (incremental) [2 of 4 in 13.19s]
    Failed test  matches_contract_fct_orders_append_new_columns_ (models/orders/fct_orders.yml:14:9) [4 of 4 in 0.20s]
```

The test's compiled SQL (in `target/compiled/.../matches_contract_fct_orders_append_new_columns_.sql`) names the mismatch:

```sql
select 'amount' as column_name, 'double' as contract_type, 'decimal(10,2)' as table_type, 'data type mismatch' as mismatch_reason
```

Check the table directly:

```bash
dbt show --limit -1 --inline "describe {{ target.schema }}.fct_orders_append_new_columns"
```

`--limit -1` matters: by default `dbt show` adds `limit 10` to the query, and Spark rejects a `limit` after `describe`.

To start over, copy `steps/1_initial` back and run `dbt build --full-refresh`.

### Reproduce it with dbt-core 1.x

dbt-spark has no Spark Connect method. Its `session` method uses PySpark, which connects to Spark Connect when `SPARK_REMOTE` is set. `profiles_core/profiles.yml` uses that, with the schema `dbt_schema_change_core`:

```bash
export SPARK_REMOTE=sc://localhost:15002
export DBT_PROFILES_DIR=profiles_core
CORE="uvx --python 3.12 --from dbt-core~=1.11.0 --with dbt-spark[session]~=1.10 --with pyspark[connect]==4.2.0 dbt"

$CORE deps
cp steps/rejected/* models/orders/
$CORE parse --target-path target_core     # ValidationError: Invalid value for on_schema_change: ...

cp steps/1_initial/* models/orders/
$CORE build --target-path target_core --full-refresh
cp steps/2_add_status/* models/orders/
$CORE build --target-path target_core -s path:models/orders
cp steps/3_retype_amount/* models/orders/
$CORE build --target-path target_core -s path:models/orders
# 1 of 4 OK created sql incremental model dbt_schema_change_core.fct_orders_append_new_columns
# 2 of 4 ERROR creating sql incremental model dbt_schema_change_core.fct_orders_fail
# 3 of 4 FAIL 1 matches_contract_fct_orders_append_new_columns_
# 4 of 4 SKIP test matches_contract_fct_orders_fail_
```

dbt-core reports the parse error as a Python traceback that ends in `dbt_common.dataclass_schema.ValidationError`, not as a formatted error. `--target-path target_core` keeps the dbt-core manifest apart from the dbt v2 one in `target/`.

## Which value to use

| `on_schema_change` | Allowed with an enforced contract | Table stays in sync with the contract |
| --- | --- | --- |
| `ignore` (the default) | no, parse fails | n/a |
| `sync_all_columns` | no, parse fails | n/a |
| `append_new_columns` | yes | **only for added columns.** Type changes and removed columns drift silently (or fail with a database error, depending on the adapter). |
| `fail` | yes | yes. Any schema change stops the run until you run `--full-refresh` or change the table yourself. |

- **Use `fail` when the table must match the contract.** Every schema change then needs a deliberate step: a `--full-refresh`, or an `alter table` you run yourself.
- **Use `append_new_columns` only together with a test like `matches_contract`.** Then a type change or a removed column fails `dbt build` right after the model runs, instead of going unnoticed.
- **Set `on_schema_change` explicitly** on every contracted incremental model. If you leave it unset, the default `ignore` fails at parse time, which is safe but surprising.

## The `matches_contract` test

`tests/generic/matches_contract.sql` is a generic test that does what the contract doesn't: it compares the table in the database with the columns in the model's YAML. It returns one row per difference:

| `mismatch_reason` | Meaning |
| --- | --- |
| `data type mismatch` | The column has a different type in the table |
| `column missing from table` | The YAML declares a column that the table doesn't have |
| `column not in contract` | The table has a column that the YAML doesn't declare |

How it works:

- It finds the model's node in `graph.nodes` and reads the declared `data_type` of each column.
- It reads the table's columns with `adapter.get_columns_in_relation(model)`.
- It compares the two, case-insensitively and without spaces, so `decimal(10, 2)` matches `decimal(10,2)`.

The lookup runs only inside `{% if execute %}`. dbt-core parses the project with an empty `graph`, so without the guard the parse fails with `'dict object' has no attribute 'nodes'`. dbt 2.0.9 doesn't need the guard, but accepts it.

The test compares type names as text. Write `data_type` in the YAML the way the warehouse reports it (on Spark, `describe` returns `decimal(10,2)`, `bigint`, `string`), or the test reports a mismatch where there is none.

## Notes

- **The contract is checked before the merge, against the SQL only.** On an incremental run, the materialization creates a temporary relation with `get_create_table_as_sql`, which calls `get_assert_columns_equivalent`. A contract error fails the run before the existing table changes. A contract that passes says nothing about the existing table.
- **`fail` stays failed.** Once `fct_orders_fail` fails, every later run fails too, until you rebuild it with `dbt build --full-refresh -s fct_orders_fail`.
- **Pin seed types.** On Postgres, dbt-core 1.11 loads integers from a CSV seed as `integer` and dbt 2.0.9 as `bigint`, which breaks a `bigint` contract on one of the two. `dbt_project.yml` pins the types of `seeds/orders.csv` with `column_types`, so the contract doesn't depend on type inference.

## Project layout

| Path | Purpose |
| --- | --- |
| `seeds/orders.csv` | Sample orders loaded with `dbt seed` (types pinned in `dbt_project.yml`) |
| `seeds/customers.csv` | Sample customer data (used by `customer_full_names`) |
| `models/customer_full_names.sql` | View that combines first and last name into `full_name` |
| `models/orders/` | The current step: `fct_orders_append_new_columns`, `fct_orders_fail` and their contract (`fct_orders.yml`) |
| `steps/` | The SQL and YAML for each step; copy one over `models/orders/` |
| `tests/generic/matches_contract.sql` | Generic test that compares the live table with the YAML contract |
| `packages.yml` | dbt package dependencies (`dbt-labs/dbt_utils` 1.x) |
| `pyproject.toml` / `uv.lock` | Python environment; pins `dbt==2.0.9` |
| `env_standard` | Environment variables the project needs (see below) |
| `profiles.yml` | dbt v2 connection to Spark Connect on `localhost:15002`, schema `dbt_schema_change` |
| `profiles_core/profiles.yml` | dbt-core 1.x connection through PySpark, schema `dbt_schema_change_core` |

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
         schema: dbt_schema_change
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

## Troubleshooting

| Error | Fix |
| --- | --- |
| `Invalid value for on_schema_change: ignore` | Expected for `steps/rejected`. Elsewhere, set `on_schema_change` to `append_new_columns` or `fail` |
| `The source and target schemas on this incremental model are out of sync!` | Expected for `fct_orders_fail` after step 1; rebuild with `--full-refresh` |
| `'dict object' has no attribute 'nodes'` in a test on dbt-core | Wrap the `graph` lookup in `{% if execute %}` (see `matches_contract`) |
| `The 'spark' adapter is not yet supported` | `env_standard` isn't loaded; see [Environment variables](#environment-variables) |
| `the URL path (/) must be empty or have a proper parameter syntax` | Put the port in `host` (`"localhost:15002/;user_id=dbt"`) and remove `port`; see [Setup](#setup) |
| `Syntax error at or near 'limit'` from `dbt show` | Add `--limit -1` when the query is a `describe ...` or `show ...` statement |
| `The selection criterion 'fqn:orders+' does not match` | `orders` is both a seed and a folder; select the folder with `-s path:models/orders` |
| `Could not find profile named 'dbt_utils_demo'` | Pass `--profiles-dir .` or set `DBT_PROFILES_DIR` |
