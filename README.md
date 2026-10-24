# dbt_utils_demo: `run_query()` vs `statement()` for Delta `OPTIMIZE`

This branch shows why swapping `statement(..., fetch_result=False)` for `run_query()` in an `OPTIMIZE ... ZORDER BY` post-hook crashes dbt 2.0.9 on Spark with Delta Lake, while dbt-core 1.x runs the same code without complaint.

This branch uses the same dbt v2 and uv setup as [`concat_macro_overrides`](https://github.com/stanislawbartkowski/dbt_samples/tree/concat_macro_overrides), but on Spark (through Spark Connect) instead of Postgres, and without the `concat` override. dbt-core 1.x runs through `uvx`; nothing extra is installed in the project. See [Setup](#setup) below.

## The problem

> "A teammate changed our `OPTIMIZE` post-hook from `statement()` to `run_query()`. The SQL is the same, but now `dbt run` crashes with `declared as non-nullable but contains null values`."

`run_query()` and `statement()` send the same SQL, but they don't handle the result the same way:

- **`run_query()`** always fetches the result set and turns it into a table you can read in Jinja.
- **`statement(..., fetch_result=False)`** runs the SQL and ignores the result.

Delta's `OPTIMIZE` returns one row of metrics. Spark declares some nested metric columns as non-nullable, but returns nulls in them, for example `metrics.clusteringStats.inputZCubeFiles.numFiles`. When dbt 2.0.9 converts that row, it checks nullability and stops:

```
panic: panicked at fs/sa/crates/dbt-agate/src/flat_record_batch.rs:44:26:
called `Result::unwrap()` on an `Err` value: InvalidArgumentError("Column 'metrics/clusteringStats/inputZCubeFiles/numFiles' is declared as non-nullable but contains null values")
```

dbt-core 1.x doesn't check nullability on fetched results, so the same macro works there.

## The example

`seeds/customers.csv` holds 4 customers. Two Delta models copy it and run `OPTIMIZE ... ZORDER BY (customer_id)` in a post-hook. The macros are identical except for the call that sends the SQL (`macros/run_optimize.sql`):

```sql
{# BROKEN #}
{% macro run_optimize_naive(relation, zorder_fields=[]) %}
  {% do run_query(optimize_sql(relation, zorder_fields)) %}
{% endmacro %}

{# FIXED: only the call changes #}
{% macro run_optimize_safe(relation, zorder_fields=[]) %}
  {% call statement('run_optimize_safe', fetch_result=False) %}
    {{ optimize_sql(relation, zorder_fields) }}
  {% endcall %}
{% endmacro %}
```

Each model calls one of them:

```sql
{{ config(
    materialized='table',
    file_format='delta',
    post_hook="{{ run_optimize_naive(this, ['customer_id']) }}"
) }}

select * from {{ ref('customers') }}
```

### Reproduce it with dbt 2.0.9

```bash
source .venv/bin/activate
set -a; source env_standard; set +a
export DBT_PROFILES_DIR=.

dbt deps
dbt seed
dbt run -s customers_optimized_safe    # succeeds
dbt run -s customers_optimized_naive   # panics, exit code 2
```

### Reproduce it with dbt-core 1.x

dbt-spark has no Spark Connect method. Its `session` method uses PySpark, which connects to Spark Connect when `SPARK_REMOTE` is set. `profiles_core/profiles.yml` uses that, with the schema `dbt_fetch_result_core`:

```bash
export SPARK_REMOTE=sc://localhost:15002
export DBT_PROFILES_DIR=profiles_core
CORE="uvx --python 3.12 --from dbt-core~=1.11.0 --with dbt-spark[session]~=1.10 --with pyspark[connect]==4.2.0 dbt"

$CORE seed --target-path target_core
$CORE run -s customers_optimized_naive --target-path target_core   # succeeds
```

`--target-path target_core` keeps the dbt-core manifest apart from the dbt v2 one in `target/`.

### What each command does with `customers_optimized_naive`

| Command | dbt-core 1.11.16 | dbt 2.0.9 |
| --- | --- | --- |
| `dbt run`, `dbt build` | succeeds | **panics** |
| `dbt compile`, `dbt show`, `dbt docs generate` | – | succeeds |

`customers_optimized_safe` succeeds in every command in both versions. Tested with Spark 4.2.0, Delta Lake 4.4.1 and dbt-spark 1.11.0. dbt 2.0.8 behaves the same as 2.0.9.

The panic is worse than a failed model:

- **It stops the whole invocation.** `dbt run` on all models exits with code 2 and prints no summary. Models that hadn't run yet don't run, and nothing reports which ones were skipped.
- **`OPTIMIZE` has already finished.** `describe history dbt_fetch_result.customers_optimized_naive` shows an `OPTIMIZE` version after each run. Spark did the work; dbt crashes afterwards, while reading the metrics row.

## Notes

- **`ZORDER` isn't the trigger.** `OPTIMIZE` without `ZORDER BY` panics too, on a different column (`metrics/zOrderStats/inputCubeFiles/num`). Any `run_query()` whose result has this mismatch fails the same way.
- **A plain-SQL hook also works.** dbt doesn't type-check what hook SQL returns, so this runs in dbt 2.0.9:

  ```sql
  {{ config(post_hook="optimize {{ this }} zorder by (customer_id)") }}
  ```

  Use a macro with `statement()` when the hook needs logic, such as an optional `ZORDER BY`.
- **Rule of thumb:** use `run_query()` only when you read the result in Jinja. For maintenance and DDL whose result you ignore (`OPTIMIZE`, `VACUUM`, grants, drops), use `statement(..., fetch_result=False)` or plain hook SQL.
- **Not every command is affected.** In this setup, `VACUUM`, `DESCRIBE HISTORY`, `DESCRIBE DETAIL` and about 20 plain Spark commands (`ANALYZE`, `DESCRIBE`, `SHOW ...`, `CACHE`) returned results that dbt 2.0.9 read without errors.

## Project layout

| Path | Purpose |
| --- | --- |
| `seeds/customers.csv` | Sample customer data loaded with `dbt seed` |
| `models/customer_full_names.sql` | View that combines first and last name into `full_name` |
| `macros/run_optimize.sql` | `optimize_sql`, `run_optimize_naive` (`run_query`) and `run_optimize_safe` (`statement`) |
| `models/customers_optimized_naive.sql` | Delta table with the `run_query()` post-hook (panics in dbt 2.0.9) |
| `models/customers_optimized_safe.sql` | Same table with the `statement()` post-hook |
| `packages.yml` | dbt package dependencies (`dbt-labs/dbt_utils` 1.x) |
| `pyproject.toml` / `uv.lock` | Python environment; pins `dbt==2.0.9` |
| `env_standard` | Environment variables the project needs (see below) |
| `profiles.yml` | dbt v2 connection to Spark Connect on `localhost:15002`, schema `dbt_fetch_result` |
| `profiles_core/profiles.yml` | dbt-core 1.x connection through PySpark, schema `dbt_fetch_result_core` |

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
         schema: dbt_fetch_result
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
dbt run --profiles-dir .                         # build models (panics on customers_optimized_naive)
dbt run --profiles-dir . --exclude customers_optimized_naive
dbt show --profiles-dir . -s customer_full_names # preview model output
dbt clean --profiles-dir .                       # remove target/ and dbt_packages/
```

To skip passing `--profiles-dir .` each time, run `export DBT_PROFILES_DIR=.`.

### Example: preview `customer_full_names`

```bash
uv run --env-file env_standard dbt show --profiles-dir . --select customer_full_names
```

Output (first rows; Spark returns them in no fixed order):

```
│ customer_id ┆ first_name ┆ last_name ┆ full_name   │
╞═════════════╪════════════╪═══════════╪═════════════╡
│ 3           ┆ Alice      ┆ Brown     ┆ Alice Brown │
│ 2           ┆ Jane       ┆ Smith     ┆ Jane Smith  │
│ 4           ┆ Bob        ┆ Jones     ┆ Bob Jones   │
```

`dbt show` returns 10 rows by default. Use `--limit 20` to change that, or `--limit -1` to show all rows.

## Troubleshooting

| Error | Fix |
| --- | --- |
| `The 'spark' adapter is not yet supported` | `env_standard` isn't loaded; see [Environment variables](#environment-variables) |
| `the URL path (/) must be empty or have a proper parameter syntax` | Put the port in `host` (`"localhost:15002/;user_id=dbt"`) and remove `port`; see [Setup](#setup) |
| `declared as non-nullable but contains null values` | A `run_query()` fetched a result dbt v2 can't convert; use `statement(..., fetch_result=False)` |
| `Could not find profile named 'dbt_utils_demo'` | Pass `--profiles-dir .` or set `DBT_PROFILES_DIR` |
