# dbt_utils_demo

A small dbt v2 project for Postgres. It loads a `customers` seed and builds a `customer_full_names` view with dbt's `concat` macro. The project overrides `concat` to join fields with `' - '`. The `dbt_utils` package is installed as a dependency.

## Project layout

| Path | Purpose |
| --- | --- |
| `seeds/customers.csv` | Sample customer data loaded with `dbt seed` |
| `models/customer_full_names.sql` | View that combines first and last name into `full_name` |
| `macros/concat.sql` | Overrides `dbt.concat` on Postgres to join fields with `' - '` |
| `packages.yml` | dbt package dependencies (`dbt-labs/dbt_utils` 1.x) |
| `pyproject.toml` / `uv.lock` | Python environment; pins `dbt==2.0.8` |
| `env_standard` | Environment variables the project needs (see below) |
| `profiles.yml` | Your connection settings. Git ignores it; you create it yourself |

## Prerequisites

- A running Postgres instance (by default `localhost:5432`, database `dbt_edu`)
- [uv](https://docs.astral.sh/uv/getting-started/installation/)

## Setup

1. **Install dbt v2.** It is pinned in `pyproject.toml`:

   ```bash
   uv sync
   uv run dbt --version   # dbt 2.0.8
   ```

2. **Create `profiles.yml`** in the project root:

   ```yaml
   dbt_utils_demo:
     target: dev
     outputs:
       dev:
         type: postgres
         host: localhost
         port: 5432
         user: dbt
         password: <your-password>   # dbt v2 requires `password`, not `pass`
         dbname: dbt_edu
         schema: dbt_utils_demo
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
│ customer_id ┆ first_name ┆ last_name ┆ full_name     │
╞═════════════╪════════════╪═══════════╪═══════════════╡
│ 1           ┆ John       ┆ Doe       ┆ John - Doe    │
│ 2           ┆ Jane       ┆ Smith     ┆ Jane - Smith  │
│ 3           ┆ Alice      ┆ Brown     ┆ Alice - Brown │
```

### Custom `concat` separator

`macros/concat.sql` defines `postgres__concat`. dbt checks this project's macros before its own, so every `dbt.concat([...])` call joins its fields with `' - '`:

```sql
{{ dbt.concat(['first_name', 'last_name']) }}   -- compiles to: first_name || ' - ' || last_name
```

#### How the override works

dbt's built-in `concat` doesn't contain any SQL. It passes the call to a database-specific macro:

```sql
{% macro concat(fields) %}
  {{ return(adapter.dispatch('concat', 'dbt')(fields)) }}
{% endmacro %}
```

On Postgres, dbt looks for these macros in order and uses the first one it finds:

1. `postgres__concat` in **this project** ← our override
2. `default__concat` in **this project**
3. `postgres__concat` in **dbt**
4. `default__concat` in **dbt**

This project defines `postgres__concat`, so dbt uses it and never calls its own version. Models don't need any changes: they still call `dbt.concat`. To make the override apply on every database, not just Postgres, name the macro `default__concat` instead.

Run `dbt compile -s customer_full_names` to see the SQL it produces.

The override also applies inside packages: `dbt_utils.generate_surrogate_key` produces different hashes than it would with dbt's default `concat`. It also changes null handling. The override uses `||`, so if any field is null, the result is null. dbt's default `concat` skips nulls instead.

`dbt show` returns 10 rows by default. Use `--limit 20` to change that, or `--limit -1` to show all rows.

## Troubleshooting

| Error | Fix |
| --- | --- |
| `The 'postgres' adapter is not yet supported` | `env_standard` isn't loaded; see [Environment variables](#environment-variables) |
| `missing field 'password'` | Rename `pass:` to `password:` in `profiles.yml` |
| `the concat macro is now provided in dbt Core` | Use `{{ dbt.concat(...) }}` instead of `{{ dbt_utils.concat(...) }}` |
| `Could not find profile named 'dbt_utils_demo'` | Pass `--profiles-dir .` or set `DBT_PROFILES_DIR` |
