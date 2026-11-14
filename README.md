# dbt_utils_demo: why Slim CI rebuilds more, or less, than it should

This branch tests three common explanations for a Slim CI job (`dbt build --select state:modified+ --state <prod manifest>`) that rebuilds the whole DAG on every PR. It runs each one on dbt-core 1.11.17 and on dbt 2.0.11:

- **`--state` and `--target-path` in the same directory make Slim CI build too little, not too much.** dbt overwrites the prod manifest with the PR's own manifest, so nothing looks modified and the changed model isn't built at all. dbt-core does this on the first command and prints a warning. dbt 2.0.11 compares correctly on the first command, then overwrites the manifest, so every later command in the same job silently selects nothing.
- **Configs that depend on `target.name` are false positives only on dbt-core, and only when they're set in `config()` or in properties YAML.** Configs in `dbt_project.yml` are always compared unrendered. `state_modified_compare_more_unrendered_values: true` fixes the rest on dbt-core 1.9 to 1.11. dbt 2.0.11 doesn't have the problem, with or without the flag.
- **A shared macro edit is the cause that really rebuilds everything.** A comment added inside a macro that every model calls marks every model as `state:modified.macros`, on both versions.

Diagnose before you change anything: run `dbt ls --select state:modified --state <prod manifest>`, then the sub-selectors (`state:modified.body`, `.configs`, `.macros`, and others) to see *why* each model is selected. See [Diagnose it](#diagnose-it).

This branch uses the same dbt v2 and uv setup as [`concat_macro_overrides`](https://github.com/stanislawbartkowski/dbt_samples/tree/concat_macro_overrides), with two Postgres targets: `prod` and `ci`. dbt-core 1.x runs through `uvx`; nothing extra is installed in the project. See [Setup](#setup) below.

## The problem

A common explanation goes like this:

> Three recurring root causes. First, `--state` and `--target-path` pointing at the same directory: dbt overwrites `target/manifest.json` during parsing before it's used for comparison, so "previous state" has already been overwritten with the current run's manifest by the time dbt diffs — everything looks unmodified or everything looks new, depending on wiring. Second, environment-aware Jinja in configs: if `materialized` branches on `target.name`, the rendered config differs between environments, and older dbt versions compare rendered values — a permanent false positive on every such model. dbt 1.9's `state_modified_compare_more_unrendered_values` flag addresses this. Third, macro-change fan-out: a shared macro edit marks every dependent model as `state:modified.macros`.

Parts of it are right:

- **A shared state and target directory loses the prod manifest.** dbt-core even warns about it: `The state and target directories are the same`.
- **Target-dependent configs are false positives on dbt-core with the flag off**, and the flag fixes them.
- **A macro edit marks every model that calls the macro**, even when the edit is a comment.

Other parts don't hold:

- **A shared directory never makes everything look new.** It makes everything look unmodified: the PR's change isn't built or tested, and CI passes. A missing prod manifest doesn't rebuild everything either. It's an error on both versions.
- **It isn't every model with a target-dependent config.** Even with the flag off, dbt-core compares configs set in `dbt_project.yml` unrendered. Only configs set in a model's `config()` block or in properties YAML are compared rendered.
- **It isn't every dbt version.** dbt 2.0.11 always compares the unrendered value, so the flag changes nothing there.

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

| Scenario | Expected | dbt-core 1.11.17 | dbt 2.0.11 |
| --- | --- | --- | --- |
| **1.** One-line change to `fct_orders`, `--state prod-state` | `fct_orders` | `fct_orders` | `fct_orders` |
| **1.** Same change, prod manifest copied into `target/`, `--state target` | `fct_orders` | **nothing**, warning | `fct_orders` |
| **1.** The next command in the same job, `--state target` | `fct_orders` | **nothing**, warning | **nothing**, no warning |
| **2.** No change, flag `false` | nothing | **`customer_revenue`, `fct_orders`** (`.configs`) | nothing |
| **2.** No change, flag `true` | nothing | nothing | nothing |
| **3.** Jinja comment added inside `audit_columns()` | all five (`.macros`) | all five (`.macros`) | all five (`.macros`) |
| **3.** Same comment above the `{% macro %}` block | nothing | nothing | nothing |

"Flag" is `state_modified_compare_more_unrendered_values` in `dbt_project.yml`. `dim_customers` is never selected in scenario 2: its config comes from `dbt_project.yml`. Tested on Postgres 14.

### Reproduce it with dbt 2.0.11

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
  ...
  state_modified_compare_more_unrendered_values: false
    state:modified -> (nothing)
    state:modified.configs -> (nothing)
  ...

== Cause 3: a comment added inside a shared macro
    state:modified -> customer_revenue dim_customers fct_orders stg_customers stg_orders
    state:modified.body -> (nothing)
    state:modified.macros -> customer_revenue dim_customers fct_orders stg_customers stg_orders
  The same comment above the {% macro %} block instead:
    state:modified -> (nothing)
```

### Reproduce it with dbt-core 1.x

`profiles_core/profiles.yml` uses the schemas `dbt_slim_ci_prod_core` and `dbt_slim_ci_pr_core`. `TARGET_DIR=target_core` keeps the dbt-core manifest apart from the dbt v2 one:

```bash
DBT="uvx --python 3.12 --from dbt-core~=1.11.0 --with dbt-postgres~=1.10 dbt" \
DBT_PROFILES_DIR=profiles_core TARGET_DIR=target_core \
./slim_ci_demo.sh
```

```
== Cause 1: --state and --target-path are the same directory
  ...
  Prod manifest copied into target_core/, --state target_core:
    state:modified -> (nothing)
    (warning: The state and target directories are the same)
  ...
== Cause 2: configs that depend on target.name
  ...
  state_modified_compare_more_unrendered_values: false
    state:modified -> customer_revenue fct_orders
    state:modified.configs -> customer_revenue fct_orders
  state_modified_compare_more_unrendered_values: true
    state:modified -> (nothing)
    state:modified.configs -> (nothing)
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

**Cause 1.** Every dbt command parses the project and writes `manifest.json` to the target path. dbt-core writes it before it reads the `--state` manifest, so with a shared directory it compares the PR with itself. dbt 2.0.11 behaves as if it reads the `--state` manifest first: its first command still works. But the file in `target/` is now the PR's manifest, so any later command in the job, such as a retry, `dbt test` after `dbt run`, or `dbt docs generate` before `dbt build`, compares the PR with itself.

**Cause 2.** dbt stores both the rendered config (`materialized: table` in prod, `view` in CI) and the unrendered one (the Jinja text). Comparing the rendered values flags every target-dependent config. With the flag off, dbt-core 1.11.17 compares unrendered values only for `dbt_project.yml` configs. The flag (added in 1.9) adds configs from `config()` and properties YAML. dbt 2.0.11 always compares unrendered values.

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
| `.configs` only, on models with `target.name` in `config()` or YAML | Rendered config comparison (cause 2) |
| `.macros`, on every model | A macro that every model calls was edited (cause 3) |
| The same models flagged on every PR, after an upgrade | The prod manifest comes from a different dbt version (see [Notes](#notes)) |
| `Got a state selector method, but no comparison manifest` (dbt-core) or `Failed to load manifest.json from state path` (dbt v2) | `--state` points at a directory with no `manifest.json` |

## What to do

- **Keep the prod manifest in its own directory.** Download it to `prod-state/`, never to `target/`, and pass `--state prod-state`. On dbt-core, treat `The state and target directories are the same` as an error.
- **On dbt-core 1.9 to 1.11, turn on the flag:**

  ```yaml
  flags:
    state_modified_compare_more_unrendered_values: true
  ```

  Build the prod manifest with the flag on too. On dbt 2.0.11 the flag isn't needed.
- **Don't rule out a real macro change.** A full rebuild after a macro edit is usually correct: the SQL of every caller may have changed. Check with `state:modified.macros`, and keep cosmetic edits to widely used macros out of feature PRs. Selecting only `state:modified.body+ state:modified.configs+` would skip a real macro change, so it isn't a fix.
- **Check that Slim CI selects something.** A Slim CI job that builds nothing passes. Fail the job when a PR changes files under `models/` and `dbt ls --select state:modified` is empty.

## Setup

1. **Install dbt v2.** It is pinned in `pyproject.toml`:

   ```bash
   uv sync
   uv run dbt --version   # dbt 2.0.11
   ```

2. **Check `profiles.yml`.** It is included and has two Postgres outputs, `prod` and `ci`, in different schemas. `ci` is the default target:

   ```yaml
   dbt_utils_demo:
     outputs:
       prod:
         type: postgres
         host: localhost
         port: 5432
         user: dbt
         password: secret
         dbname: dbt_edu
         schema: dbt_slim_ci_prod
         threads: 1
       ci:
         type: postgres
         host: localhost
         port: 5432
         user: dbt
         password: secret
         dbname: dbt_edu
         schema: dbt_slim_ci_pr
         threads: 1
     target: ci
   ```

   Change the credentials to match your server.

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

## Troubleshooting

| Error | Fix |
| --- | --- |
| `The state and target directories are the same` | Expected in scenario 1 on dbt-core; in a real job, move the prod manifest out of `target/` |
| `Got a state selector method, but no comparison manifest` | dbt-core: no `manifest.json` in the `--state` directory |
| `Failed to load manifest.json from state path` | dbt v2: no `manifest.json` in the `--state` directory |
| `dbt parse failed` from `slim_ci_demo.sh` | Run `dbt parse --target prod` directly to see the error; usually `env_standard` isn't loaded or `DBT_PROFILES_DIR` isn't set |
| `The 'postgres' adapter is not yet supported` | `env_standard` isn't loaded; see [Environment variables](#environment-variables) |
| `Could not find profile named 'dbt_utils_demo'` | Pass `--profiles-dir .` or set `DBT_PROFILES_DIR` |

## Notes

- **Compare manifests from the same dbt version.** dbt-core and dbt 2.0.11 store the unrendered `config()` value differently: dbt-core stores a parsed Jinja expression, `Keyword(key='materialized', value=CondExpr(...))`, and dbt 2.0.11 stores the source text. A dbt 2.0.11 CI job compared against a dbt-core prod manifest, or the other way round, flags `fct_orders` on every PR, with the flag on. During an upgrade, rebuild the prod manifest with the new version first.
- **`state:modified+` adds everything downstream.** In this project the macro edit already selects every model. In a larger one, a macro used by a few staging models selects them and every model built on them.

## Project layout

| Path | Purpose |
| --- | --- |
| `slim_ci_demo.sh` | Runs every scenario in a scratch copy of the project and prints what `state:modified` selects |
| `macros/audit_columns.sql` | The macro every model calls |
| `models/staging/stg_*.sql` | Staging views over the seeds |
| `models/marts/*.sql` | Marts; tables in prod and views in CI |
| `models/marts/marts.yml` | Sets `customer_revenue`'s materialization from `target.name` |
| `seeds/orders.csv`, `seeds/customers.csv` | Sample data (types pinned in `dbt_project.yml`) |
| `dbt_project.yml` | `state_modified_compare_more_unrendered_values: true`, and `dim_customers`'s materialization |
| `packages.yml` | dbt package dependencies (`dbt-labs/dbt_utils` 1.x) |
| `pyproject.toml` / `uv.lock` | Python environment; pins `dbt==2.0.11` |
| `env_standard` | Environment variables the project needs (see above) |
| `profiles.yml` | dbt v2 connections: `prod` and `ci` (default) on Postgres, schemas `dbt_slim_ci_prod` and `dbt_slim_ci_pr` |
| `profiles_core/profiles.yml` | dbt-core 1.x connections, schemas `dbt_slim_ci_prod_core` and `dbt_slim_ci_pr_core` |

## Prerequisites

- A running Postgres instance (by default `localhost:5432`, database `dbt_edu`). This branch was tested with Postgres 14.
- [uv](https://docs.astral.sh/uv/getting-started/installation/)
