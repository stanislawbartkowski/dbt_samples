# dbt_utils_demo: Jinja loop scoping

This branch shows why a list built with `{% set %}` inside a `{% for %}` loop is empty after the loop, and two ways to fix it: `namespace()` and `{% do list.append() %}`.

This branch uses the same dbt v2 and uv setup as [`concat_macro_overrides`](https://github.com/stanislawbartkowski/dbt_samples/tree/concat_macro_overrides), but on Spark (through Spark Connect) instead of Postgres, and without the `concat` override. dbt-core 1.x runs through `uvx`; nothing extra is installed in the project. See [Setup](#setup) below.

## The problem

> "Our post-hook macro loops over query results and appends each id to a list. The values are clearly there inside the loop, but the list is always empty after it."

This is standard Jinja scoping, not a dbt bug, and a global variable won't fix it. A `{% for %}` loop opens its own scope. `{% set found_ids = found_ids + [...] %}` inside the loop doesn't change the outer `found_ids`. It creates a new `found_ids` in the loop's scope. The next iteration starts again from the outer, empty list, and the inner one disappears at `{% endfor %}`. Python works differently: there a `for` loop doesn't open a new scope.

`{% if %}` blocks don't open a scope. A `{% set %}` inside an `if` is visible after `{% endif %}`. The bug only happens in loops.

## The example

`macros/comment_with_ids.sql` has three post-hook macros. Each one reads the `customer_id`s from the view it runs on and stores them in the view's `customer_ids` table property. They differ only in how they build the list:

```sql
{# BROKEN: the set inside the loop binds a new found_ids that disappears at endfor #}
{% set found_ids = [] %}
{% for row in results %}
  {% set found_ids = found_ids + [row['customer_id']] %}
{% endfor %}
alter view {{ relation }} set tblproperties ('customer_ids' = '{{ found_ids | join(", ") }}')

{# FIXED: a namespace attribute set inside the loop is still visible after it #}
{% set ns = namespace(found_ids=[]) %}
{% for row in results %}
  {% set ns.found_ids = ns.found_ids + [row['customer_id']] %}
{% endfor %}
alter view {{ relation }} set tblproperties ('customer_ids' = '{{ ns.found_ids | join(", ") }}')

{# ALSO FIXED: append mutates the list in place instead of rebinding the name #}
{% set found_ids = [] %}
{% for row in results %}
  {% do found_ids.append(row['customer_id']) %}
{% endfor %}
alter view {{ relation }} set tblproperties ('customer_ids' = '{{ found_ids | join(", ") }}')
```

`namespace()` is Jinja's official fix. It works for any value, including counters, strings and flags (`{% set ns.total = ns.total + 1 %}`). `append` works because it changes the list object, not the name, but only for lists and dicts.

Each macro is the post-hook of one model, and each model is `select * from {{ ref('customers') }}`:

| Model | Post-hook | `customer_ids` property |
| --- | --- | --- |
| `customers_commented_naive` | `comment_with_ids_naive` | **empty** |
| `customers_commented` | `comment_with_ids` (`namespace`) | `1, 2, 3, 4` |
| `customers_commented_append` | `comment_with_ids_append` | `1, 2, 3, 4` |

The results are the same on dbt 2.0.9 and dbt-core 1.11.16 with dbt-spark 1.11.0, tested on Spark 4.2.0.

**Nothing fails.** `dbt build` succeeds for all three models. The broken hook still produces valid SQL, just with an empty list. You only notice when you read the hook's SQL or the property itself. This pattern is common in dbt macros, which often loop over `graph.nodes.values()`, query results or column lists to build SQL.

**What to look for in code review:** a `{% set %}` inside a `{% for %}` loop that assigns a variable which is read after the loop. If you find one, use `namespace()`.

### Reproduce it with dbt 2.0.9

Set up the shell and build everything:

```bash
source .venv/bin/activate
set -a; source env_standard; set +a
export DBT_PROFILES_DIR=.

dbt build    # all models succeed, including customers_commented_naive
```

`dbt build` passes for all three models, so it can't tell you which hook is broken. Use one of the checks below.

`dbt show --select customers_commented_naive` doesn't show the bug either. It returns the view's 4 customers, and they are correct: the model's SQL is just `select * from customers`. The bug is in the post-hook that runs after the view is created, and the only thing it writes is the view's `customer_ids` property.

#### Scenario 1: the broken macro leaves the property empty

```bash
dbt show --limit -1 --inline "show tblproperties {{ target.schema }}.customers_commented_naive ('customer_ids')"
```

```
│ key          ┆ value │
│ customer_ids ┆       │
```

The loop added every id, but the list is empty after `{% endfor %}`.

#### Scenario 2: the fixed macros record every id

```bash
dbt show --limit -1 --inline "show tblproperties {{ target.schema }}.customers_commented ('customer_ids')"
dbt show --limit -1 --inline "show tblproperties {{ target.schema }}.customers_commented_append ('customer_ids')"
```

Both print:

```
│ key          ┆ value      │
│ customer_ids ┆ 1, 2, 3, 4 │
```

`--limit -1` matters in both scenarios: by default `dbt show` adds `limit 10` to the query, and Spark rejects a `limit` after `show tblproperties`.

#### Scenario 3: compare the SQL the hooks ran

This check doesn't depend on where the hook saves its result. Run the broken and the fixed model with `--log-level debug`:

```bash
dbt run -s customers_commented_naive customers_commented --log-level debug | grep "alter view"
```

```
alter view `dbt_jinja_scoping`.`customers_commented_naive` set tblproperties ('customer_ids' = '')
alter view `dbt_jinja_scoping`.`customers_commented` set tblproperties ('customer_ids' = '1, 2, 3, 4')
```

dbt 2 also writes every statement it runs to `logs/query_log.sql`:

```bash
grep "alter view" logs/query_log.sql | tail -3
```

### Reproduce it with dbt-core 1.x

dbt-spark has no Spark Connect method. Its `session` method uses PySpark, which connects to Spark Connect when `SPARK_REMOTE` is set. `profiles_core/profiles.yml` uses that, with the schema `dbt_jinja_scoping_core`:

```bash
export SPARK_REMOTE=sc://localhost:15002
export DBT_PROFILES_DIR=profiles_core
CORE="uvx --python 3.12 --from dbt-core~=1.11.0 --with dbt-spark[session]~=1.10 --with pyspark[connect]==4.2.0 dbt"

$CORE build --target-path target_core
grep "alter view" logs/dbt.log
```

`--target-path target_core` keeps the dbt-core manifest apart from the dbt v2 one in `target/`.

## Notes

- **Why `if execute`?** dbt renders the hooks while parsing too, when `run_query` returns nothing. The macros only run the query and output the `alter view` statement when `execute` is true.
- **What a `log` inside the loop shows.** Each iteration starts again from the outer, empty `found_ids`, so `{{ log(found_ids, info=true) }}` inside the loop prints `[1]`, `[2]`, `[3]`, not a growing list. After `{% endfor %}` it prints `[]`.

## Project layout

| Path | Purpose |
| --- | --- |
| `seeds/customers.csv` | Sample customer data loaded with `dbt seed` |
| `models/customer_full_names.sql` | View that combines first and last name into `full_name` |
| `macros/comment_with_ids.sql` | `comment_with_ids_naive`, `comment_with_ids` (`namespace`) and `comment_with_ids_append` |
| `models/customers_commented_naive.sql` | View with the broken post-hook |
| `models/customers_commented.sql` | View with the `namespace` post-hook |
| `models/customers_commented_append.sql` | View with the `append` post-hook |
| `packages.yml` | dbt package dependencies (`dbt-labs/dbt_utils` 1.x) |
| `pyproject.toml` / `uv.lock` | Python environment; pins `dbt==2.0.9` |
| `env_standard` | Environment variables the project needs (see below) |
| `profiles.yml` | dbt v2 connection to Spark Connect on `localhost:15002`, schema `dbt_jinja_scoping` |
| `profiles_core/profiles.yml` | dbt-core 1.x connection through PySpark, schema `dbt_jinja_scoping_core` |

## Prerequisites

- A Spark Connect server on `localhost:15002`. This branch was tested with Spark 4.2.0. The models are plain views and don't use Delta Lake. For example:

  ```bash
  $SPARK_HOME/sbin/start-connect-server.sh \
    --packages org.apache.spark:spark-connect_2.13:4.2.0 \
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
         schema: dbt_jinja_scoping
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
dbt run --profiles-dir .                         # build models
dbt build --profiles-dir .                       # seed + run + test, in order
dbt show --profiles-dir . -s customer_full_names # preview a model
dbt clean --profiles-dir .                       # remove target/ and dbt_packages/
```

To skip passing `--profiles-dir .` each time, run `export DBT_PROFILES_DIR=.`.

## Troubleshooting

| Error | Fix |
| --- | --- |
| `The 'spark' adapter is not yet supported` | `env_standard` isn't loaded; see [Environment variables](#environment-variables) |
| `the URL path (/) must be empty or have a proper parameter syntax` | Put the port in `host` (`"localhost:15002/;user_id=dbt"`) and remove `port`; see [Setup](#setup) |
| `Syntax error at or near 'limit'` from `dbt show` | Add `--limit -1` when the query is a `show ...` statement |
| The `customer_ids` property is empty | A `{% set %}` inside a `for` loop rebinds the list; use `namespace()` or `{% do list.append() %}` |
| `Could not find profile named 'dbt_utils_demo'` | Pass `--profiles-dir .` or set `DBT_PROFILES_DIR` |
