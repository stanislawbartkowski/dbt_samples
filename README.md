# dbt_utils_demo: guarding a package against missing macros

This branch shows how a package can check for a macro before calling it, so users on an older dbt get a clear error instead of a cryptic Jinja one. It also shows that the check from the dbt docs, `dbt.get('date_spine')`, always fails on dbt 2.0.9, and that dbt 2.0.9 ignores `require-dbt-version`.

This branch uses the same dbt v2, Postgres and uv setup as [`concat_macro_overrides`](https://github.com/stanislawbartkowski/dbt_samples/tree/concat_macro_overrides), without the `concat` override. dbt-core 1.x runs through `uvx`; nothing extra is installed in the project. See [Setup](#setup) below.

## The problem

> "Our package calls `dbt.date_spine`. Users on an older dbt-core get `'dict object' has no attribute 'date_spine'` and the whole project fails to parse."

`dbt.date_spine` ships with dbt-core 1.7 and later. dbt-core 1.6 doesn't have it, and a package that calls it there fails with a Jinja error that doesn't say what's missing or which dbt version is needed.

Two mechanisms help, and you usually want both:

- **`require-dbt-version`** in the package's `dbt_project.yml` is the coarse guard. dbt-core refuses to run outside the range and says which version is needed. Users can skip it with `--no-version-check`, and it can't help when only *part* of the package needs a newer dbt.
- **A check in Jinja** before the call is the fine-grained guard. The package can raise a clear error, or fall back to other SQL when the macro is optional.

## The example

`packages/calendar_utils` is a small local package (installed from `packages.yml` with `local:`). Its macros all return one row per day of September 2020 in a `date_day` column. They differ only in how they deal with `dbt.date_spine` (`packages/calendar_utils/macros/days_in_september.sql`):

```sql
{# BROKEN on dbt-core 1.6: no guard #}
{% macro days_in_september_naive() %}
  {{ dbt.date_spine("day", "cast('2020-09-01' as date)", "cast('2020-10-01' as date)") }}
{% endmacro %}

{# BROKEN on dbt 2: the guard from the dbt docs #}
{% macro days_in_september_docs_guard() %}
  {% if not dbt.get('date_spine') %}
    {{ exceptions.raise_compiler_error("calendar_utils: expected to find the dbt.date_spine macro, but it could not be found") }}
  {% endif %}
  {{ dbt.date_spine(...) }}
{% endmacro %}

{# FIXED, hard requirement: only the check changes #}
{% macro days_in_september_safe() %}
  {% if dbt.date_spine is not defined %}
    {{ exceptions.raise_compiler_error("...") }}
  {% endif %}
  {{ dbt.date_spine(...) }}
{% endmacro %}

{# FIXED, soft dependency: fall back when the macro is missing #}
{% macro days_in_september() %}
  {% if dbt.date_spine is defined %}
    {{ dbt.date_spine(...) }}
  {% else %}
    {% for i in range(30) %}
      select {{ dbt.dateadd("day", i, "cast('2020-09-01' as date)") }} as date_day
      {% if not loop.last %}union all{% endif %}
    {% endfor %}
  {% endif %}
{% endmacro %}
```

The package also sets the coarse guard (`packages/calendar_utils/dbt_project.yml`):

```yaml
require-dbt-version: [">=1.6.0", "<3.0.0"]
```

The lower bound is 1.6, not 1.7, because only part of the package needs `dbt.date_spine`: `days_in_september` still works on 1.6 through its fallback. The upper bound keeps the package from running on a future major version nobody has tested.

The model `models/september_days.sql` calls `calendar_utils.days_in_september()`, which works on every version here. The other three macros are run one at a time with `dbt show --inline`. On dbt-core 1.6, a macro that fails stops parsing for the whole project, even in a model that isn't selected or is disabled, so each one gets its own command.

### What each macro does

| Macro | dbt-core 1.6.19 | dbt-core 1.11.16 | dbt 2.0.9 |
| --- | --- | --- | --- |
| `days_in_september_naive` | **fails:** `'dict object' has no attribute 'date_spine'` | 30 rows | 30 rows |
| `days_in_september_docs_guard` | clear error | 30 rows | **fails:** clear error, but `date_spine` exists |
| `days_in_september_safe` | clear error | 30 rows | 30 rows |
| `days_in_september` (fallback) | 30 rows | 30 rows | 30 rows |

The clear error is `calendar_utils: expected to find the dbt.date_spine macro, but it could not be found`.

**`dbt.get()` doesn't work on dbt 2.0.9.** It returns `none` for every macro, including ones that exist, such as `dbt.get('concat')`. A guard written as `{% if not dbt.get('date_spine') %}` always raises. Use `dbt.date_spine is defined` (or `is not defined`). It behaves the same on dbt-core 1.6, dbt-core 1.11 and dbt 2.0.9.

### What `require-dbt-version` does

| Command | Result |
| --- | --- |
| dbt-core 1.5.12 | **fails:** `This version of dbt is not supported with the 'calendar_utils' package.` with the installed and required versions |
| dbt-core 1.5.12 with `--no-version-check` | the check is skipped |
| dbt-core 1.6.19, 1.11.16 | runs |
| dbt 2.0.9 | runs, **whatever the range says** |

dbt 2.0.9 doesn't enforce `require-dbt-version` in a package or in the root project. `[">=1.9.0", "<2.0.0"]` and even `">=3.0.0"` run without an error or a warning. On dbt v2, the Jinja check is the only guard that works.

dbt 2.0.9 also reports itself as `2.0.0` in the `dbt_version` Jinja variable, so don't compare `dbt_version` to check for a feature. Check for the macro itself.

### Reproduce it with dbt 2.0.9

```bash
source .venv/bin/activate
set -a; source env_standard; set +a
export DBT_PROFILES_DIR=.

dbt deps
dbt build    # seed, customer_full_names and september_days all succeed

dbt show --inline "select count(*) as days from ({{ calendar_utils.days_in_september_naive() }}) d"       # 30
dbt show --inline "select count(*) as days from ({{ calendar_utils.days_in_september_docs_guard() }}) d"  # error
dbt show --inline "select count(*) as days from ({{ calendar_utils.days_in_september_safe() }}) d"        # 30
dbt show --inline "select count(*) as days from ({{ calendar_utils.days_in_september() }}) d"             # 30
```

To see that `require-dbt-version` is ignored, set it to `">=3.0.0"` in `packages/calendar_utils/dbt_project.yml` and run `dbt parse`. `dbt_packages/calendar_utils` is a symlink to `packages/calendar_utils`, so you don't need to run `dbt deps` again.

### Reproduce it with dbt-core 1.x

`profiles_core/profiles.yml` uses the same Postgres with the schema `dbt_macro_guards_core`:

```bash
export DBT_PROFILES_DIR=profiles_core
CORE16="uvx --python 3.11 --from dbt-core~=1.6.0 --with dbt-postgres~=1.6.0 dbt"

$CORE16 deps
$CORE16 build --target-path target_core   # succeeds; september_days uses the fallback
$CORE16 show --target-path target_core --inline "select count(*) as days from ({{ calendar_utils.days_in_september_naive() }}) d"
# 'dict object' has no attribute 'date_spine'
$CORE16 show --target-path target_core --inline "select count(*) as days from ({{ calendar_utils.days_in_september_safe() }}) d"
# calendar_utils: expected to find the dbt.date_spine macro, but it could not be found

CORE15="uvx --python 3.11 --from dbt-core~=1.5.0 --with dbt-postgres~=1.5.0 dbt"
$CORE15 parse --target-path target_core   # This version of dbt is not supported with the 'calendar_utils' package.
```

For dbt-core 1.11, use `--from dbt-core~=1.11.0 --with dbt-postgres~=1.11.0`. `--target-path target_core` keeps the dbt-core manifest apart from the dbt v2 one in `target/`.

## Notes

- **Raise at parse time or at run time?** dbt-core renders every model while parsing, so the raise in `days_in_september_safe` stops the whole project on 1.6, not just the model that calls it. That's usually what you want for a hard requirement. dbt 2.0.9 reports the error for that model and keeps building the others.
- **Check and call the same name.** The macros use `dbt.date_spine` in both the check and the call. The example in the dbt docs checks `dbt.get('date_spine')` but calls a bare `date_spine(...)`, which a root project with its own `date_spine` macro can override, so the check and the call can look at different macros.

## Project layout

| Path | Purpose |
| --- | --- |
| `seeds/customers.csv` | Sample customer data loaded with `dbt seed` |
| `models/customer_full_names.sql` | View that combines first and last name into `full_name` |
| `packages/calendar_utils/dbt_project.yml` | The local package, with `require-dbt-version: [">=1.6.0", "<3.0.0"]` |
| `packages/calendar_utils/macros/days_in_september.sql` | `days_in_september_naive`, `_docs_guard`, `_safe` and the fallback `days_in_september` |
| `models/september_days.sql` | View that calls `calendar_utils.days_in_september()` |
| `packages.yml` | dbt package dependencies (`dbt-labs/dbt_utils` 1.x and the local `calendar_utils`) |
| `pyproject.toml` / `uv.lock` | Python environment; pins `dbt==2.0.9` |
| `env_standard` | Environment variables the project needs (see below) |
| `profiles.yml` | dbt v2 connection to a local Postgres (generic `dbt` / `secret` credentials), schema `dbt_macro_guards` |
| `profiles_core/profiles.yml` | dbt-core 1.x connection, schema `dbt_macro_guards_core` |

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
         schema: dbt_macro_guards
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
dbt show --profiles-dir . -s september_days      # preview the calendar model
dbt clean --profiles-dir .                       # remove target/ and dbt_packages/
```

To skip passing `--profiles-dir .` each time, run `export DBT_PROFILES_DIR=.`.

## Troubleshooting

| Error | Fix |
| --- | --- |
| `The 'postgres' adapter is not yet supported` | `env_standard` isn't loaded; see [Environment variables](#environment-variables) |
| `missing field 'password'` | Rename `pass:` to `password:` in `profiles.yml` |
| `expected to find the dbt.date_spine macro` on dbt v2 | The guard uses `dbt.get(...)`; use `dbt.date_spine is defined` instead |
| `'dict object' has no attribute 'date_spine'` | dbt-core is older than 1.7; upgrade or use a fallback |
| `Could not find profile named 'dbt_utils_demo'` | Pass `--profiles-dir .` or set `DBT_PROFILES_DIR` |
