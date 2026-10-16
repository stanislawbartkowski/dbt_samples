# dbt_utils_demo: Jinja whitespace control

This branch shows how Jinja whitespace control, or the lack of it, breaks the SQL that dbt compiles. The examples are in `models/jinja_whitespace/`. Each broken model has a `_fixed` version next to it.

This branch uses the same dbt v2, Postgres and uv setup as [`concat_macro_overrides`](https://github.com/stanislawbartkowski/dbt_samples/tree/concat_macro_overrides), without the `concat` override. See [Setup](#setup) below.

## The problem

> "A model compiles fine locally, but in CI it produces SQL with a stray comma. It only happens inside a `{% for %}` loop with an `{% if %}` inside it. The Jinja logic is correct."

By default, every `{% ... %}` tag leaves its line break and indentation in the output, and dbt doesn't strip them. The `-` modifier strips whitespace on one side of a tag: `{%- ... %}` strips before the tag and `{% ... -%}` strips after it. Too little stripping buries problems under blank lines. Too much glues tokens together or pulls code into a `--` comment. Code review often misses these bugs, because the diff looks harmless while the compiled SQL is wrong.

## The examples

| Model | Fails on | What goes wrong |
| --- | --- | --- |
| `ci_trailing_comma` | `--target ci` only | Stray comma before `FROM` |
| `glued_tokens` | every target | `selectcustomer_id,...` (database syntax error) |
| `comment_eats_sql` | nothing (silent) | Builds, but `last_name` is missing |

The first two are tagged `broken`. The default selector in `selectors.yml` excludes that tag, so a plain `dbt build` still passes. Run a broken model explicitly to see it fail.

All commands below assume this setup:

```bash
source .venv/bin/activate
set -a; source env_standard; set +a
export DBT_PROFILES_DIR=.
```

### 1. Stray comma only in CI: `ci_trailing_comma`

```sql
select
{% for col in columns %}
    {% if not (target.name == 'ci' and col == 'last_name') %}
    {{ col }}{% if not loop.last %},{% endif %}
    {% endif %}
{% endfor %}
from {{ ref('customers') }}
```

`profiles.yml` has a second target, `ci`, that hides the PII column `last_name`. On `dev`, the loop outputs every column. On `ci`, it skips the last one, but `loop.last` still refers to the full list, so `first_name` keeps its comma:

```bash
dbt compile -s ci_trailing_comma              # dev: fine
dbt compile -s ci_trailing_comma --target ci  # ci: see the output below
dbt run     -s ci_trailing_comma --target ci  # syntax error at or near "from"
```

```sql
select

    
    
    customer_id,
    

    
    
    first_name,
    

    
    

from "dbt_edu"."dbt_jinja_spaces_ci"."customers"
```

**Why "only in CI"?** Whitespace handling is deterministic, so the environment doesn't change how it behaves. CI runs with different inputs (here, `target.name`), which takes a different branch of the `if`. Without whitespace control, every tag leaves a blank line, so the dangling comma is buried in empty space and hard to spot.

**Fix** (`ci_trailing_comma_fixed`): filter the list *before* the loop, so `loop.last` refers to the last column actually output. Add `-` only on the loop tags:

```sql
{%- if target.name == 'ci' -%}
    {%- set columns = columns | reject('equalto', 'last_name') | list -%}
{%- endif %}

select
{%- for col in columns %}
    {{ col }}{{ "," if not loop.last }}
{%- endfor %}
from {{ ref('customers') }}
```

```sql
select
    customer_id,
    first_name
from "dbt_edu"."dbt_jinja_spaces_ci"."customers"
```

### 2. Too much stripping: `glued_tokens`

Adding `-` on both sides of every tag also removes the spaces SQL needs between words:

```sql
select
    {%- for col in columns -%}
    {{ col }}{{ "," if not loop.last }}
    {%- endfor -%}
from {{ ref('customers') }}
```

```sql
selectcustomer_id,first_name,last_namefrom "dbt_edu"."dbt_jinja_spaces"."customers"
```

```bash
dbt run -s glued_tokens   # syntax error at or near "selectcustomer_id"
```

**Fix** (`glued_tokens_fixed`): strip only *before* each tag (`{%- for %}`, `{%- endfor %}`). That keeps the line break after `select` and before `from`.

### 3. A comment eats code: `comment_eats_sql`

This is the most dangerous case, because nothing fails:

```sql
    first_name -- optional columns below
    {%- if var('include_last_name', true) -%}
    , last_name
    {%- endif %}
```

The `-%}` strips the line break after the tag, and that line break was what ended the `--` comment. `, last_name` moves onto the comment line:

```sql
select
    customer_id,
    first_name -- optional columns below, last_name
from "dbt_edu"."dbt_jinja_spaces"."customers"
```

```bash
dbt show -s comment_eats_sql --limit 1   # columns: customer_id, first_name (no last_name)
```

**Fix** (`comment_eats_sql_fixed`): use `{%- if ... %}` without the trailing `-`, so the line break that ends the comment stays.

## Takeaways

- **Check the compiled SQL, not the Jinja.** Use `dbt compile -s <model>` or look in `target/compiled/`, and compile for every target you deploy to (`--target ci`).
- **Add `-` only on the tag closest to the problem.** Adding it to every tag in a macro causes problem 2.
- **Never let a `-%}` follow a `--` comment.** Use `/* ... */` comments in Jinja-heavy SQL.
- **For trailing separators, filter first, then loop**, or build a list and use `| join(', ')`. Then commas never depend on `loop.last`.
- **dbt compile won't catch these.** `dbt compile` succeeds for all three models. The errors only appear when Postgres runs the SQL, and problem 3 never errors at all.

## Project layout

| Path | Purpose |
| --- | --- |
| `seeds/customers.csv` | Sample customer data loaded with `dbt seed` |
| `models/customer_full_names.sql` | View that combines first and last name into `full_name` |
| `packages.yml` | dbt package dependencies (`dbt-labs/dbt_utils` 1.x) |
| `pyproject.toml` / `uv.lock` | Python environment; pins `dbt==2.0.8` |
| `env_standard` | Environment variables the project needs (see below) |
| `profiles.yml` | Connection settings for a local Postgres (generic `dbt` / `secret` credentials). Targets: `dev` (default) and `ci` (schema `dbt_jinja_spaces_ci`) |
| `models/jinja_whitespace/` | Whitespace-control demos: broken models and their `_fixed` versions |
| `selectors.yml` | Default selector that excludes models tagged `broken` |

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
         schema: dbt_jinja_spaces
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
