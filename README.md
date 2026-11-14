# dbt_utils_demo: why Slim CI rebuilds more, or less, than it should

This branch tests three common explanations for a Slim CI job (`dbt build --select state:modified+ --state <prod manifest>`) that rebuilds the whole DAG on every PR. It runs each one on dbt 2.0.11:

- **`--state` and `--target-path` in the same directory make Slim CI build too little, not too much.** The first command still compares against the prod manifest, then overwrites it with the PR's own manifest. Every later command in the same job compares the PR with itself, selects nothing, and prints no warning.
- **Configs that depend on `target.name` aren't false positives.** dbt 2.0.11 compares the unrendered config, the Jinja text, so `table` in prod and `view` in CI don't count as a change. `state_modified_compare_more_unrendered_values` has no effect.
- **A shared macro edit is the cause that really rebuilds everything.** A comment added inside a macro that every model calls marks every model as `state:modified.macros`.

Diagnose before you change anything: run `dbt ls --select state:modified --state <prod manifest>`, then the sub-selectors (`state:modified.body`, `.configs`, `.macros`, and others) to see *why* each model is selected. See [Diagnose it](#diagnose-it).

This branch uses the same dbt v2 and uv setup as [`concat_macro_overrides`](https://github.com/stanislawbartkowski/dbt_samples/tree/concat_macro_overrides), with two Spark targets (through Spark Connect, with Delta Lake): `prod` and `ci`. See [Setup](#setup) below.

## The problem

A common explanation goes like this:

> Three recurring root causes. First, `--state` and `--target-path` pointing at the same directory: dbt overwrites `target/manifest.json` during parsing before it's used for comparison, so "previous state" has already been overwritten with the current run's manifest by the time dbt diffs — everything looks unmodified or everything looks new, depending on wiring. Second, environment-aware Jinja in configs: if `materialized` branches on `target.name`, the rendered config differs between environments, and older dbt versions compare rendered values — a permanent false positive on every such model. dbt 1.9's `state_modified_compare_more_unrendered_values` flag addresses this. Third, macro-change fan-out: a shared macro edit marks every dependent model as `state:modified.macros`.

Parts of it are right:

- **A shared state and target directory loses the prod manifest.** After the first dbt command, `target/manifest.json` is the PR's manifest.
- **A macro edit marks every model that calls the macro**, even when the edit is a comment.

Other parts don't hold:

- **A shared directory never makes everything look new.** It makes everything look unmodified: the PR's change isn't built or tested, and CI passes. A missing prod manifest doesn't rebuild everything either. It's an error.
- **Target-dependent configs aren't false positives on dbt 2.0.11.** It compares unrendered values, wherever the config is set: `dbt_project.yml`, `config()` or properties YAML. The flag makes no difference.

## The example

Five models, each calling the macro `audit_columns()` (`macros/audit_columns.sql`):

```sql
{% macro audit_columns() -%}
    current_timestamp as _loaded_at
{%- endmacro %}
```

```
customers ─ stg_customers ─ dim_customers ─┐
                                           ├─ customer_revenue
orders ──── stg_orders ──── fct_orders ────┘
```

The three marts are tables in prod and views everywhere else. Each sets that in a different place:

| Model | Where `materialized` is set |
| --- | --- |
| `dim_customers` | `dbt_project.yml`: `+materialized: "{{ 'table' if target.name == 'prod' else 'view' }}"` |
| `fct_orders` | its own `config()`: `{{ config(materialized="table" if target.name == "prod" else "view") }}` |
| `customer_revenue` | `models/marts/marts.yml`: `materialized: "{{ 'table' if target.name == 'prod' else 'view' }}"` |

The prod job writes its manifest with `dbt parse --target prod --target-path prod-state`. The CI job lists what Slim CI would build with `dbt ls --target ci --select state:modified --state prod-state`. `slim_ci_demo.sh` runs every scenario in a scratch copy of the project, so the repo isn't changed.

## Results

Each cell lists the models that `state:modified` selects.

| Scenario | Expected | dbt 2.0.11 |
| --- | --- | --- |
| **1.** One-line change to `fct_orders`, `--state prod-state` | `fct_orders` | `fct_orders` |
| **1.** Same change, prod manifest copied into `target/`, `--state target` | `fct_orders` | `fct_orders` |
| **1.** The next command in the same job, `--state target` | `fct_orders` | **nothing**, no warning |
| **2.** No change, flag `false` | nothing | nothing |
| **2.** No change, flag `true` | nothing | nothing |
| **3.** Jinja comment added inside `audit_columns()` | all five (`.macros`) | all five (`.macros`) |
| **3.** Same comment above the `{% macro %}` block | nothing | nothing |

"Flag" is `state_modified_compare_more_unrendered_values` in `dbt_project.yml`. Tested on Spark 4.2.0 with Delta Lake 4.4.1. The results were the same on Postgres 14.

### Reproduce it

```bash
source .venv/bin/activate
set -a; source env_standard; set +a
export DBT_PROFILES_DIR=.
dbt deps
./slim_ci_demo.sh
```

```
== Cause 1: --state and --target-path are the same directory
  The PR changes one line in fct_orders.
  Separate directories (--state prod-state):
    state:modified -> fct_orders
  Prod manifest copied into target/, --state target:
    state:modified -> fct_orders
  The next dbt command in the same job, --state target:
    state:modified -> (nothing)

== Cause 2: configs that depend on target.name
  No change at all. fct_orders sets materialized in config(),
  customer_revenue in marts.yml, dim_customers in dbt_project.yml.
  state_modified_compare_more_unrendered_values: false
    state:modified -> (nothing)
    state:modified.configs -> (nothing)
  state_modified_compare_more_unrendered_values: true
    state:modified -> (nothing)
    state:modified.configs -> (nothing)

== Cause 3: a comment added inside a shared macro
    state:modified -> customer_revenue dim_customers fct_orders stg_customers stg_orders
    state:modified.body -> (nothing)
    state:modified.macros -> customer_revenue dim_customers fct_orders stg_customers stg_orders
  The same comment above the {% macro %} block instead:
    state:modified -> (nothing)
```

### Run Slim CI for real

The script only parses. To build:

```bash
# Prod job: build, then keep the manifest outside target/
dbt build --target prod
mkdir -p prod-state && cp target/manifest.json prod-state/

# CI job, on the PR branch: build only what changed, and everything downstream
dbt build --target ci --select state:modified+ --state prod-state
```

The marts are tables in `dbt_slim_ci_prod` and views in `dbt_slim_ci_pr`.

## Why it happens

dbt selects `state:modified` by comparing each node in the current manifest with the same node in the `--state` manifest. A node is modified when any of these differ, and each has its own sub-selector:

| Sub-selector | Compares |
| --- | --- |
| `state:modified.body` | the model's SQL |
| `state:modified.configs` | its configs |
| `state:modified.relation` | database, schema, alias |
| `state:modified.persisted_descriptions` | descriptions, when `persist_docs` is on |
| `state:modified.macros` | every macro the model calls, directly or through other macros |
| `state:modified.contract` | its contract |

**Cause 1.** Every dbt command parses the project and writes `manifest.json` to the target path. dbt 2.0.11 behaves as if it reads the `--state` manifest first, so the first command still compares against prod. But the file in `target/` is now the PR's manifest, so any later command in the job, such as a retry, `dbt test` after `dbt run`, or `dbt docs generate` before `dbt build`, compares the PR with itself.

**Cause 2.** dbt stores both the rendered config (`materialized: table` in prod, `view` in CI) and the unrendered one (the Jinja text). dbt 2.0.11 compares the unrendered one, so a target-dependent config only counts as modified when its Jinja text changes.

**Cause 3.** dbt compares the source of each macro, from `{% macro %}` to `{% endmacro %}`. It can't tell a comment from a change in the SQL the macro generates, so any edit marks every caller. Edits outside the block, such as a comment at the top of the file, aren't part of the macro and don't count.

## Diagnose it

Before changing the CI job, find out which nodes are selected and why. Compare against a known-good prod manifest:

```bash
dbt ls --select state:modified --state prod-state --resource-type model
dbt ls --select state:modified.body --state prod-state --resource-type model
dbt ls --select state:modified.configs --state prod-state --resource-type model
dbt ls --select state:modified.macros --state prod-state --resource-type model
```

| What you see | Likely cause |
| --- | --- |
| Nothing, although the PR changes a model | `--state` and `--target-path` are the same directory (cause 1) |
| `.macros`, on every model | A macro that every model calls was edited (cause 3) |
| `Failed to load manifest.json from state path` | `--state` points at a directory with no `manifest.json` |

## What to do

- **Keep the prod manifest in its own directory.** Download it to `prod-state/`, never to `target/`, and pass `--state prod-state`. dbt 2.0.11 doesn't warn when the two are the same, so check the CI job's paths.
- **You don't need `state_modified_compare_more_unrendered_values`.** dbt 2.0.11 already compares unrendered configs.
- **Don't rule out a real macro change.** A full rebuild after a macro edit is usually correct: the SQL of every caller may have changed. Check with `state:modified.macros`, and keep cosmetic edits to widely used macros out of feature PRs. Selecting only `state:modified.body+ state:modified.configs+` would skip a real macro change, so it isn't a fix.
- **Check that Slim CI selects something.** A Slim CI job that builds nothing passes. Fail the job when a PR changes files under `models/` and `dbt ls --select state:modified` is empty.

## Setup

1. **Install dbt v2.** It is pinned in `pyproject.toml`:

   ```bash
   uv sync
   uv run dbt --version   # dbt 2.0.11
   ```

2. **Check `profiles.yml`.** It is included and has two Spark Connect outputs, `prod` and `ci`, in different schemas. `ci` is the default target:

   ```yaml
   dbt_utils_demo:
     outputs:
       prod:
         type: spark
         method: spark-connect
         host: localhost
         port: 15002
         schema: dbt_slim_ci_prod
         threads: 1
       ci:
         type: spark
         method: spark-connect
         host: localhost
         port: 15002
         schema: dbt_slim_ci_pr
         threads: 1
     target: ci
   ```

   Use a plain `host` and `port`, as above. dbt 2.0.9 needed a workaround (`host: "localhost:15002/;user_id=dbt"` without `port`); dbt 2.0.11 rejects it.

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
| `Failed to load manifest.json from state path` | No `manifest.json` in the `--state` directory |
| `dbt parse failed` from `slim_ci_demo.sh` | Run `dbt parse --target prod` directly to see the error; usually `env_standard` isn't loaded or `DBT_PROFILES_DIR` isn't set |
| `The 'spark' adapter is not yet supported` | `env_standard` isn't loaded; see [Environment variables](#environment-variables) |
| `Could not parse Spark Connect port: strconv.Atoi: parsing "15002/;user_id=dbt"` | The profile still has the dbt 2.0.9 workaround; use `host: localhost` and `port: 15002`; see [Setup](#setup) |
| `Could not find profile named 'dbt_utils_demo'` | Pass `--profiles-dir .` or set `DBT_PROFILES_DIR` |

## Notes

- **`state:modified+` adds everything downstream.** In this project the macro edit already selects every model. In a larger one, a macro used by a few staging models selects them and every model built on them.

## Project layout

| Path | Purpose |
| --- | --- |
| `slim_ci_demo.sh` | Runs every scenario in a scratch copy of the project and prints what `state:modified` selects |
| `macros/audit_columns.sql` | The macro every model calls |
| `models/staging/stg_*.sql` | Staging views over the seeds |
| `models/marts/*.sql` | Marts; Delta tables in prod and views in CI |
| `models/marts/marts.yml` | Sets `customer_revenue`'s materialization from `target.name` |
| `seeds/orders.csv`, `seeds/customers.csv` | Sample data (types pinned in `dbt_project.yml`) |
| `dbt_project.yml` | `state_modified_compare_more_unrendered_values` (no effect on dbt 2.0.11), `dim_customers`'s materialization, and `file_format: delta` for the marts |
| `packages.yml` | dbt package dependencies (`dbt-labs/dbt_utils` 1.x) |
| `pyproject.toml` / `uv.lock` | Python environment; pins `dbt==2.0.11` |
| `env_standard` | Environment variables the project needs (see above) |
| `profiles.yml` | Connections: `prod` and `ci` (default) on Spark Connect at `localhost:15002`, schemas `dbt_slim_ci_prod` and `dbt_slim_ci_pr` |

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
