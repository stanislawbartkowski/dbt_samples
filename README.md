# dbt_utils_demo: `run_query()` during parse

This branch shows what `run_query()` returns while dbt parses the project, and why reading its result without an `{% if execute %}` guard breaks `dbt parse`. In dbt 2.0.8 the same model still passes `dbt run`, so the bug can stay hidden until CI runs `dbt parse`.

This branch uses the same dbt v2, Postgres and uv setup as [`concat_macro_overrides`](https://github.com/stanislawbartkowski/dbt_samples/tree/concat_macro_overrides), without the `concat` override. dbt-core 1.x runs through `uvx`; nothing extra is installed in the project. See [Setup](#setup) below.

## The problem

> "My model calls `run_query()` and works fine in `dbt run`. In CI, `dbt parse --no-partial-parse` fails on it."

dbt works in two phases:

1. **Parse.** dbt reads every file and renders its Jinja once to collect `ref()`, `source()` and `config()` and build the DAG. No SQL runs against the warehouse. `execute` is `False`.
2. **Execution.** dbt renders the selected nodes again and runs their SQL. `execute` is `True`.

During parse, `run_query()` doesn't run the query. The `run_query()` call itself is safe at parse time; reading its result is not:

- **dbt-core 1.x** returns `None`, so `results.columns[0].values()` fails with `'None' has no attribute 'table'`.
- **dbt 2.0.8** returns an empty undefined value. Reading `.columns[0].values()` from it gives an empty list without an error, but any code that expects real data fails. Here, that's a check that the list isn't empty.

## The example

`seeds/payments.csv` holds 5 payments with 4 payment methods. Two models pivot the amounts into one column per payment method. They read the list of methods with `run_query()` and stop with an error if it is empty. The models are identical except for the `{% if execute %}` guard around reading and checking the result:

```sql
{# BROKEN: models/payments_pivot_naive.sql #}
{% set results = run_query(payment_method_query) %}
{% set payment_methods = results.columns[0].values() %}
{% if payment_methods | length == 0 %}
  {{ exceptions.raise_compiler_error("payments has no payment methods") }}
{% endif %}

{# FIXED: models/payments_pivot_safe.sql #}
{% set results = run_query(payment_method_query) %}
{% if execute %}
  {% set payment_methods = results.columns[0].values() %}
  {% if payment_methods | length == 0 %}
    {{ exceptions.raise_compiler_error("payments has no payment methods") }}
  {% endif %}
{% else %}
  {% set payment_methods = [] %}
{% endif %}
```

During parse, the safe model renders with an empty list and skips the check. The SQL it produces is invalid (`customer_id,` followed by `from`), but parse never runs it. During execution, the list holds the real payment methods.

### Reproduce it with dbt 2.0.8

```bash
source .venv/bin/activate
set -a; source env_standard; set +a
export DBT_PROFILES_DIR=.

dbt seed
dbt run                        # succeeds, including payments_pivot_naive
dbt parse --no-partial-parse   # fails
```

Output of `dbt parse`:

```
[error] [JinjaError (dbt1501)]: Failed to render SQL invalid operation: Compilation Error for dbt_utils_demo.payments_pivot_naive from models/payments_pivot_naive.sql: payments has no payment methods
  --> models/payments_pivot_naive.sql:11:3
```

### Reproduce it with dbt-core 1.x

```bash
export DBT_PROFILES_DIR=.
CORE="uvx --from dbt-core~=1.11.0 --with dbt-postgres~=1.10 dbt"

$CORE parse --no-partial-parse --target-path target_core
```

Output:

```
Compilation Error in model payments_pivot_naive (models/payments_pivot_naive.sql)
  'None' has no attribute 'table'.
```

`--target-path target_core` keeps the dbt-core manifest apart from the dbt v2 one in `target/`.

### What each command does with `payments_pivot_naive`

| Command | dbt-core 1.11.16 | dbt 2.0.8 |
| --- | --- | --- |
| `dbt parse`, `dbt ls` | **fails** | **fails** |
| `dbt run`, `dbt build`, `dbt compile`, `dbt docs generate` | **fails** | succeeds |
| `dbt run -s payments_pivot_safe` | **fails** | succeeds |

All results are with `--no-partial-parse`. `payments_pivot_safe` succeeds in every command in both versions.

In dbt 2.0.8, the commands that connect to the database still render each model during parse, but they don't report a parse-time error in a model that renders correctly during execution. `dbt parse` and `dbt ls` never connect, so they report it. A developer who only runs `dbt run` locally never sees the error; a CI step that runs `dbt parse` does.

In dbt-core, `--select` and `--exclude` don't help. Every command parses every model, so one broken model blocks every command for the whole project.

## Does partial parsing hide the bug?

A common explanation for "it worked on my machine": the partial parsing cache (`target/partial_parse.msgpack`) skips files that haven't changed, so the broken code path never renders locally. With dbt-core 1.11.16, the bug showed up on every parse that touched the code:

| Step | Result |
| --- | --- |
| Add `payments_pivot_naive.sql` to a project with a saved manifest, then `dbt parse` | **fails** |
| Remove the guard from a macro that a model calls, then `dbt parse` (partial) | **fails**: dbt re-parses every model that calls the changed macro |
| `dbt run` after either change | **fails** |

Partial parsing only skips files that already parsed successfully and haven't changed since. A file with this bug can't parse successfully in dbt-core, so the cache can't hold a good version of it. In dbt 2.0.8, `dbt parse` fails with or without partial parsing, and `dbt run` succeeds either way. If the bug shows up only in CI, compare the dbt version and the commands CI runs before blaming the cache.

## Notes

- **`log()` runs during parse too.** A `log()` call outside the `{% if execute %}` guard prints once while dbt parses and once while it executes. That makes the parse-time line look like a query already ran. `payments_pivot_safe` logs `execute=<value>`. In dbt-core, the line before `Concurrency: N threads` is from parse:

  ```
  payments_pivot_safe: execute=False
  Concurrency: 1 threads (target='dev')
  payments_pivot_safe: execute=True
  ```

  dbt v2 doesn't print a `Concurrency` line. Log `execute` itself to tell the phases apart.
- **Put the query in a macro** if several models need it, and keep the guard inside the macro so callers always get a list:

  ```sql
  {% macro get_payment_methods() %}
    {% set results = run_query("select distinct payment_method from " ~ ref('payments')) %}
    {% if execute %}
      {{ return(results.columns[0].values()) }}
    {% else %}
      {{ return([]) }}
    {% endif %}
  {% endmacro %}
  ```

- **`execute` is also `True` in `compile`, `show` and `docs generate`.** A guard on `execute` is enough for a read-only query like this one. For queries with side effects, see the [`execute_guard_side_effects`](https://github.com/stanislawbartkowski/dbt_samples/tree/execute_guard_side_effects) branch.

## Project layout

| Path | Purpose |
| --- | --- |
| `seeds/customers.csv` | Sample customer data loaded with `dbt seed` |
| `models/customer_full_names.sql` | View that combines first and last name into `full_name` |
| `seeds/payments.csv` | Payments with a `payment_method` column |
| `models/payments_pivot_naive.sql` | Pivot that reads and checks `run_query()` results without a guard (fails `dbt parse`) |
| `models/payments_pivot_safe.sql` | Same pivot with the `{% if execute %}` guard |
| `packages.yml` | dbt package dependencies (`dbt-labs/dbt_utils` 1.x) |
| `pyproject.toml` / `uv.lock` | Python environment; pins `dbt==2.0.8` |
| `env_standard` | Environment variables the project needs (see below) |
| `profiles.yml` | Connection settings for a local Postgres (generic `dbt` / `secret` credentials), schema `dbt_run_query_parse` |

## Prerequisites

- A running Postgres instance (by default `localhost:5432`, database `dbt_edu`)
- [uv](https://docs.astral.sh/uv/getting-started/installation/)

## Setup

1. **Install dbt v2.** It is pinned in `pyproject.toml`:

   ```bash
   uv sync
   uv run dbt --version   # dbt 2.0.8
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
         schema: dbt_run_query_parse
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
dbt show --profiles-dir . -s customer_full_names # preview model output
dbt clean --profiles-dir .                       # remove target/ and dbt_packages/
```

To skip passing `--profiles-dir .` each time, run `export DBT_PROFILES_DIR=.`.

### Example: preview `customer_full_names`

```bash
uv run --env-file env_standard dbt show --profiles-dir . --select customer_full_names
```

Output (first rows):

```
│ customer_id ┆ first_name ┆ last_name ┆ full_name   │
╞═════════════╪════════════╪═══════════╪═════════════╡
│ 1           ┆ John       ┆ Doe       ┆ John Doe    │
│ 2           ┆ Jane       ┆ Smith     ┆ Jane Smith  │
│ 3           ┆ Alice      ┆ Brown     ┆ Alice Brown │
```

`dbt show` returns 10 rows by default. Use `--limit 20` to change that, or `--limit -1` to show all rows.

## Troubleshooting

| Error | Fix |
| --- | --- |
| `The 'postgres' adapter is not yet supported` | `env_standard` isn't loaded; see [Environment variables](#environment-variables) |
| `missing field 'password'` | Rename `pass:` to `password:` in `profiles.yml` |
| `the concat macro is now provided in dbt Core` | Use `{{ dbt.concat(...) }}` instead of `{{ dbt_utils.concat(...) }}` |
| `Could not find profile named 'dbt_utils_demo'` | Pass `--profiles-dir .` or set `DBT_PROFILES_DIR` |
