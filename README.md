# dbt_utils_demo: numeric precision and enforced contracts

This branch tests whether `contract: {enforced: true}` catches a change in a column's numeric precision or scale. The answer depends on the adapter:

- **On Postgres, the contract ignores precision and scale.** A contract that says `numeric`, `numeric(38,0)` or `numeric(10,2)` passes against a query that returns `numeric(38,2)`. dbt then builds the table with the contract's type, so the data is rounded or the insert overflows. Both happen after the contract check passed.
- **On Spark, the contract compares precision and scale exactly.** Every one of those changes fails the contract check before the table is built.
- **The real failures on Postgres are silent rounding and data-dependent overflow.** `numeric(38,0)` turns `62.49` into `62` with no error and no warning. `numeric(10,2)` builds fine on a small dev sample and fails with `numeric field overflow` only when prod data has a total above 99,999,999.99.

The rule holds on both adapters: **always declare `numeric(precision, scale)`, never bare `numeric` or `decimal`.** But on Postgres a passing contract only means the column names and base types match. To catch rounding, test the values too. This branch includes a test for that: `sum_matches`.

This branch uses the same dbt v2 and uv setup as [`concat_macro_overrides`](https://github.com/stanislawbartkowski/dbt_samples/tree/concat_macro_overrides), with two targets: Postgres (the default) and Spark (through Spark Connect) with Delta Lake. dbt-core 1.x runs through `uvx`; nothing extra is installed in the project. See [Setup](#setup) below.

## The problem

A common explanation goes like this:

> Your team enforces `contract: enforced: true` on all mart models, but a PR that changes a column's precision from `numeric(38,2)` to bare `numeric` passes review and only fails at build time in prod. dbt's contract enforcement deliberately does not compare precision or scale, so a contract declared as `data_type: numeric` passes regardless of the actual precision and scale. If `numeric` defaults to precision 38, scale 0, the column becomes integer-only, and if the query produces fractional values, the implicit coercion during table creation fails.

Parts of it are right:

- **On Postgres, the contract check doesn't compare precision or scale.** dbt runs the model's SQL and an empty query built from the YAML types, and compares the column types the database reports for each. psycopg2 reports `numeric` for every precision, so `numeric(38,2)` and `numeric(38,0)` look the same.
- **dbt warns about bare `numeric`.** Both dbt-core 1.11.17 and dbt 2.0.11 print `Detected columns with numeric type and unspecified precision/scale, this can lead to unintended rounding`.

Other parts don't hold:

- **It isn't true for every adapter.** dbt-spark reports the full type, such as `decimal(38,2)`, so on Spark the contract fails on any change in precision or scale.
- **Bare `numeric` isn't `numeric(38,0)` everywhere.** The default depends on the database. On Postgres, bare `numeric` has no limit, so nothing is rounded. On Spark, `decimal` means `decimal(10,0)`. Precision 38 and scale 0 is Snowflake's default, which this branch doesn't test.
- **Scale 0 doesn't make the build fail.** On Postgres, inserting `62.49` into `numeric(38,0)` stores `62` and the run succeeds. The build only fails when a value is too large for the precision: a numeric overflow when the data is inserted, not an error in the DDL.

## The example

Four table models have the same SQL. `order_total` is always `numeric(38, 2)` in the query (`models/marts/dim_customers.sql`):

```sql
select
    c.customer_id,
    count(o.order_id) as order_count,
    cast(coalesce(sum(o.amount), 0) as numeric(38, 2)) as order_total
from {{ ref('customers') }} as c
left join {{ ref('stg_orders') }} as o
    on o.customer_id = c.customer_id
group by c.customer_id
```

Only the type of `order_total` in the contract changes (`models/marts/dim_customers.yml`):

| Model | Contract `order_total` | Stands for |
| --- | --- | --- |
| `dim_customers` | `numeric(38,2)` | The reviewed contract |
| `dim_customers_bare_numeric` | `numeric` | The PR: `numeric(38,2)` → bare `numeric` |
| `dim_customers_scale_0` | `numeric(38,0)` | What bare `numeric` means on Snowflake |
| `dim_customers_precision_10` | `numeric(10,2)` | Too little precision for the largest totals |

`stg_orders` stands in for dev and prod data. By default it leaves out the one large order (12,345,678,901.25), like a small dev sample. `--vars '{prod_data: true}'` builds on all orders, like prod.

Each `order_total` has a `sum_matches` test, which checks that the column adds up to the same total as `stg_orders.amount`.

## Results

| Model | Postgres, dev sample | Postgres, prod data | Spark |
| --- | --- | --- | --- |
| `dim_customers` | succeeds | succeeds | succeeds |
| `dim_customers_bare_numeric` | succeeds, **warning**; column is unbounded `numeric`, values kept | same | **contract fails:** `decimal(38,2)` ≠ `decimal(10,0)`, plus the warning |
| `dim_customers_scale_0` | **succeeds silently,** rounds to whole numbers; `sum_matches` fails | same | **contract fails:** `decimal(38,2)` ≠ `decimal(38,0)` |
| `dim_customers_precision_10` | **succeeds silently** | **fails:** `numeric field overflow` | **contract fails:** `decimal(38,2)` ≠ `decimal(10,2)` |

The results are the same on dbt 2.0.11 and on dbt-core 1.11.17 (dbt-adapters 1.24.5, dbt-postgres 1.11.0, dbt-spark 1.11.0), tested on Postgres 14 and on Spark 4.2.0 with Delta Lake 4.4.1.

`dim_customers_precision_10` is the scenario from the quote: it passes review and the dev build, then fails in prod. `dim_customers_scale_0` is worse: it never fails. Only a test of the values finds it:

```
 customer_id | dim_customers | dim_customers_scale_0
-------------+---------------+-----------------------
           1 |         62.49 |                    62
           2 |          5.00 |                     5
           3 |          7.25 |                     7
```

### Reproduce it with dbt 2.0.11

```bash
source .venv/bin/activate
set -a; source env_standard; set +a
export DBT_PROFILES_DIR=.
dbt deps

# Postgres, dev sample: all four models succeed, one warning, sum_matches fails for scale_0
dbt build

# Postgres, prod data: dim_customers_precision_10 fails with numeric field overflow
dbt build --vars '{prod_data: true}'

# Spark: the contract fails for bare_numeric, scale_0 and precision_10
dbt build --target spark
```

```
 Succeeded model dbt_numeric_precision.dim_customers_scale_0 (table) [7 of 11 in 0.15s]
    Failed test  sum_matches_dim_customers_scale_0_order_total__amount__ref_stg_orders_ (models/marts/dim_customers.yml:50:13) [11 of 11 in 0.02s]
[warning] [JinjaWarn (dbt1071)]: Detected columns with numeric type and unspecified precision/scale, this can lead to unintended rounding: ['order_total']`
```

```
[error] [DbDriverFailed (dbt1308)]: Database Error in model dim_customers_precision_10 (target/run/dbt_utils_demo/models/marts/dim_customers_precision_10.sql)
  ERROR:  numeric field overflow
  DETAIL:  A field with precision 10, scale 2 must round to an absolute value less than 10^8.
```

```
This model has an enforced contract that failed.
| column_name | definition_type | contract_type |    mismatch_reason |
| ----------- | --------------- | ------------- | ------------------ |
| order_total | decimal(38,2)   | decimal(38,0) | data type mismatch |
```

Check the column types on Postgres:

```bash
dbt show --inline "select table_name, numeric_precision, numeric_scale from information_schema.columns where table_schema = '{{ target.schema }}' and column_name = 'order_total' order by 1"
```

`dim_customers_bare_numeric` shows no precision or scale: on Postgres, bare `numeric` has no limit.

### Reproduce it with dbt-core 1.x

dbt-spark has no Spark Connect method. Its `session` method uses PySpark, which connects to Spark Connect when `SPARK_REMOTE` is set. `profiles_core/profiles.yml` uses that, with the schema `dbt_numeric_precision_core`:

```bash
export SPARK_REMOTE=sc://localhost:15002
export DBT_PROFILES_DIR=profiles_core
CORE="uvx --python 3.12 --from dbt-core~=1.11.0 --with dbt-postgres~=1.10 --with dbt-spark[session]~=1.10 --with pyspark[connect]==4.2.0 dbt"

$CORE deps
$CORE build --target-path target_core
$CORE build --target-path target_core --vars '{prod_data: true}'
$CORE build --target-path target_core --target spark
```

`--target-path target_core` keeps the dbt-core manifest apart from the dbt v2 one in `target/`.

## Why the adapters differ

The contract check is the `assert_columns_equivalent` macro in dbt-adapters. It runs two queries without returning data:

1. the model's SQL, and
2. an empty query built from the YAML, such as `select cast(null as numeric(38,0)) as order_total`.

It asks the database for the column types of each, and compares them as strings.

- **Postgres:** dbt-postgres reads the types from the psycopg2 cursor description, which gives a type code. The code for `numeric` is the same for every precision and scale, so both sides become `numeric`. dbt 2.0.11 doesn't use psycopg2, but its comparison drops precision and scale on Postgres too.
- **Spark:** dbt reads the types from Spark's schema, which includes precision and scale: `decimal(38,2)`.

When the check passes, dbt creates the table with the types from the contract, not from the query, and inserts the query's rows into it. Postgres then converts each value to the column's type: it rounds to the column's scale, and fails if the value has too many digits for the precision.

## What to do

- **Always declare precision and scale:** `numeric(38,2)`, never bare `numeric` or `decimal`. Bare types mean something different on every database: no limit on Postgres, `(10,0)` on Spark, `(38,0)` on Snowflake.
- **Make the warning an error in CI.** dbt only warns about bare `numeric`. Turn that warning into an error:

  ```bash
  dbt build --warn-error-options '{"error": ["JinjaLogWarning"]}'
  ```

  This works on dbt-core 1.11.17 and dbt 2.0.11 (which also accepts `JinjaWarn`). It covers every warning raised from Jinja, not only this one.
- **On Postgres, don't rely on the contract to check precision or scale.** A passing contract means the column names and base types match. Review changes to `data_type` in the YAML as carefully as SQL changes.
- **Test the values.** A reconciliation test such as `sum_matches` catches rounding that no type check sees. To catch overflow before prod does, make sure the CI data includes the largest values that prod has.

## The `sum_matches` test

`tests/generic/sum_matches.sql` is a generic test that fails when a column doesn't add up to the same total as a column in another model:

```yaml
      - name: order_total
        data_type: numeric(38,2)
        data_tests:
          - sum_matches:
              arguments:
                compare_model: ref('stg_orders')
                compare_column: amount
```

It returns one row with both totals when they differ, for example `74` and `74.74` for `dim_customers_scale_0`. Use it where a mart column should keep every cent of its source, such as totals and balances.

## Setup

1. **Install dbt v2.** It is pinned in `pyproject.toml`:

   ```bash
   uv sync
   uv run dbt --version   # dbt 2.0.11
   ```

2. **Check `profiles.yml`.** It is included and has two outputs. `postgres` is the default target; select Spark with `--target spark`:

   ```yaml
   dbt_utils_demo:
     outputs:
       postgres:
         type: postgres
         host: localhost
         port: 5432
         user: dbt
         password: secret
         dbname: dbt_edu
         schema: dbt_numeric_precision
         threads: 1
       spark:
         type: spark
         method: spark-connect
         host: localhost
         port: 15002
         schema: dbt_numeric_precision
         threads: 1
     target: postgres
   ```

   Change the Postgres credentials to match your server. For Spark, use a plain `host` and `port`, as above. dbt 2.0.9 needed a workaround (`host: "localhost:15002/;user_id=dbt"` without `port`); dbt 2.0.11 rejects it.

3. **Install dbt packages:**

   ```bash
   uv run --env-file env_standard dbt deps --profiles-dir .
   ```

## Environment variables

`env_standard` holds the variables dbt needs for this project:

```
DBT_ALLOW_EXPERIMENTAL_ADAPTERS=true
```

dbt v2 treats Postgres and Spark as experimental adapters and refuses to run without this flag. If it is missing, dbt fails with `The 'postgres' adapter is not yet supported`.

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
| `numeric field overflow` in `dim_customers_precision_10` | Expected with `--vars '{prod_data: true}'` on Postgres |
| `This model has an enforced contract that failed` with `data type mismatch` | Expected on Spark for every model except `dim_customers` |
| `sum_matches_dim_customers_scale_0_...` fails | Expected on Postgres: the contract passed and the values were rounded |
| `The 'postgres' adapter is not yet supported` (or `'spark'`) | `env_standard` isn't loaded; see [Environment variables](#environment-variables) |
| `Could not parse Spark Connect port: strconv.Atoi: parsing "15002/;user_id=dbt"` | The profile still has the dbt 2.0.9 workaround; use `host: localhost` and `port: 15002`; see [Setup](#setup) |
| `Ignored unexpected key "2)"` | A type such as `numeric(38,2)` inside an inline YAML list or map (`[...]`, `{...}`); put it in quotes, or use block YAML |
| `Could not find profile named 'dbt_utils_demo'` | Pass `--profiles-dir .` or set `DBT_PROFILES_DIR` |

## Notes

- **Pin seed types.** dbt-core and dbt 2 infer different types from a CSV seed (for example `integer` versus `bigint`), and so do Postgres and Spark. `dbt_project.yml` pins the types of `seeds/orders.csv` and `seeds/customers.csv` with `column_types`, so the contracts don't depend on type inference.
- **A failed build can leave the old table behind.** When `dim_customers_precision_10` fails on prod data, the table from the last successful run stays in place, with the data from that run.
- **`numeric` and `decimal` are the same type** on both Postgres and Spark. The contracts here use `numeric`; Spark reports it as `decimal`.

## Project layout

| Path | Purpose |
| --- | --- |
| `seeds/orders.csv` | Sample orders, including one large order (types pinned in `dbt_project.yml`) |
| `seeds/customers.csv` | Sample customers |
| `models/staging/stg_orders.sql` | Orders; leaves out the large order unless `prod_data` is `true` |
| `models/marts/dim_customers*.sql` | Four models with the same SQL |
| `models/marts/dim_customers.yml` | Their contracts, which differ only in the type of `order_total` |
| `tests/generic/sum_matches.sql` | Generic test that compares a column's total with a column in another model |
| `packages.yml` | dbt package dependencies (`dbt-labs/dbt_utils` 1.x) |
| `pyproject.toml` / `uv.lock` | Python environment; pins `dbt==2.0.11` |
| `env_standard` | Environment variables the project needs (see above) |
| `profiles.yml` | dbt v2 connections: Postgres (default) and Spark Connect on `localhost:15002`, schema `dbt_numeric_precision` |
| `profiles_core/profiles.yml` | dbt-core 1.x connections: Postgres and Spark through PySpark, schema `dbt_numeric_precision_core` |

## Prerequisites

- A running Postgres instance (by default `localhost:5432`, database `dbt_edu`). This branch was tested with Postgres 14.
- For the Spark target, a Spark Connect server with Delta Lake on `localhost:15002`. This branch was tested with Spark 4.2.0 and Delta Lake 4.4.1; the Delta version must match the Spark version. For example:

  ```bash
  $SPARK_HOME/sbin/start-connect-server.sh \
    --packages org.apache.spark:spark-connect_2.13:4.2.0,io.delta:delta-spark_2.13:4.4.1 \
    --conf spark.sql.extensions=io.delta.sql.DeltaSparkSessionExtension \
    --conf spark.sql.catalog.spark_catalog=org.apache.spark.sql.delta.catalog.DeltaCatalog \
    --conf spark.sql.catalogImplementation=hive
  ```

- [uv](https://docs.astral.sh/uv/getting-started/installation/)
