# dbt_utils_demo: side effects behind `{% if execute %}`

This branch shows why `{% if execute %}` doesn't stop a macro's side effects from running during `dbt compile`, `dbt docs generate` or `dbt show`, and how to limit them to `run` and `build` with `flags.WHICH`.

This branch uses the same dbt v2, Postgres and uv setup as [`concat_macro_overrides`](https://github.com/stanislawbartkowski/dbt_samples/tree/concat_macro_overrides), without the `concat` override. See [Setup](#setup) below.

## The problem

> "A macro wrapped in `{% if execute %}` still runs a `DELETE` during the nightly `dbt docs generate`, and it wipes a staging table nobody meant to touch."

`execute` doesn't mean "dbt is materializing models". It is `False` only while dbt reads the project (parse). It is `True` every time dbt compiles SQL with a live database connection: `run` and `build`, but also `compile`, `show` and `docs generate`, which compiles by default. A guard on `execute` alone can't tell real runs from compiling for docs.

## The example

Two seeds, `scratch_naive` and `scratch_safe`, each hold 3 rows. Two models call a cleanup macro that deletes from one of them. The macros are identical except for one condition in the guard (`macros/cleanup_scratch.sql`):

```sql
{# BROKEN #}
{% macro cleanup_scratch_naive() %}
  {% if execute %}
    {% do run_query("delete from " ~ ref('scratch_naive')) %}
  {% endif %}
{% endmacro %}

{# FIXED: only the guard changes #}
{% macro cleanup_scratch_safe() %}
  {% if execute and flags.WHICH in ['run', 'build'] %}
    {% do run_query("delete from " ~ ref('scratch_safe')) %}
  {% endif %}
{% endmacro %}
```

Both checks are needed. dbt renders the macro twice in each command: first while reading the project (`execute` is `False`), then while compiling (`execute` is `True`). During `dbt run`, `flags.WHICH` is already `'run'` in the first pass. So `flags.WHICH` alone would fire the delete while dbt is still reading the project, and `execute` alone fires it in `compile`, `show` and `docs generate`.

Both macros also log `DELETE fired during '<command>'`, so you can see when the delete runs.

### Reproduce it

```bash
source .venv/bin/activate
set -a; source env_standard; set +a
export DBT_PROFILES_DIR=.

dbt deps
dbt seed                          # both scratch tables: 3 rows
dbt run-operation scratch_counts  # scratch_naive: 3 rows, scratch_safe: 3 rows

dbt docs generate                 # log: cleanup_scratch_naive: DELETE fired during 'compile'
dbt run-operation scratch_counts  # scratch_naive: 0 rows, scratch_safe: 3 rows
```

Run `dbt seed` again to restore the rows before trying the next command.

### What each command does (dbt 2.0.8, Postgres)

| Command | `execute` | `flags.WHICH` | `scratch_naive` | `scratch_safe` |
| --- | --- | --- | --- | --- |
| `dbt parse`, `dbt ls` | `False` | `parse` / `list` | kept | kept |
| `dbt compile` | `True` | `compile` | **deleted** | kept |
| `dbt docs generate` | `True` | `compile` | **deleted** | kept |
| `dbt show -s customers_naive_cleanup` | `True` | `show` | **deleted** | kept |
| `dbt docs generate --no-compile` | – | – | kept | kept |
| `dbt run`, `dbt build` | `True` | `run` / `build` | deleted (intended) | deleted (intended) |

In dbt v2, `dbt docs generate` reports `flags.WHICH == 'compile'`, not `'generate'`, so a guard that only excludes `'generate'` would still delete. Allow the commands you want (`['run', 'build']`) rather than excluding the ones you don't.

## Notes

- **Optional: `statement(..., fetch_result=False)` instead of `run_query`.** For DML and DDL you don't need a result set. `statement` skips fetching it and lets you write the SQL as a block:

  ```sql
  {% call statement('cleanup_scratch_safe', fetch_result=False) %}
    delete from {{ ref('scratch_safe') }}
  {% endcall %}
  ```

  This is a style choice, not part of the fix. In this setup (dbt 2.0.8, Postgres), `run_query` runs the `DELETE` without errors.
- **A `ref()` inside `{% if %}` needs `-- depends_on:`.** dbt v2 rejects a `ref()` that only runs inside a conditional (`unable to infer all dependencies`). Each model declares the dependency with a comment at the top:

  ```sql
  -- depends_on: {{ ref('scratch_naive') }}
  {{ cleanup_scratch_naive() }}
  ```

- **Add `--no-compile` to scheduled docs jobs** if they only need the catalog. It also skips every compile-time side effect.
- **Better still, keep side effects out of model SQL.** Write the `DELETE` as plain SQL in a hook (`pre_hook="delete from {{ ref('scratch_safe') }}"`). dbt runs hook SQL only during `run` and `build`; this setup confirmed it doesn't run during `compile`, `show` or `docs generate`. Watch out: dbt v2 still renders the hook's Jinja during `compile`, so a `run_query` *inside* a hook would fire there. For one-off maintenance, use `dbt run-operation`.

## Project layout

| Path | Purpose |
| --- | --- |
| `seeds/customers.csv` | Sample customer data loaded with `dbt seed` |
| `models/customer_full_names.sql` | View that combines first and last name into `full_name` |
| `seeds/scratch_naive.csv`, `seeds/scratch_safe.csv` | Scratch tables that the cleanup macros delete from |
| `macros/cleanup_scratch.sql` | `cleanup_scratch_naive` (broken guard) and `cleanup_scratch_safe` (fixed guard) |
| `macros/scratch_counts.sql` | `dbt run-operation scratch_counts` prints the row count of each scratch table |
| `models/customers_naive_cleanup.sql`, `models/customers_safe_cleanup.sql` | Models that call the cleanup macros |
| `packages.yml` | dbt package dependencies (`dbt-labs/dbt_utils` 1.x) |
| `pyproject.toml` / `uv.lock` | Python environment; pins `dbt==2.0.8` |
| `env_standard` | Environment variables the project needs (see below) |
| `profiles.yml` | Connection settings for a local Postgres (generic `dbt` / `secret` credentials), schema `dbt_execute_guard` |

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
         schema: dbt_execute_guard
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
