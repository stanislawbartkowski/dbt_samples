# dbt_utils_demo: `--defer` runs one test across dev and prod data

This branch shows how `--defer` lets a `relationships` test compare a dev table with a prod table, with no error and no warning. It runs every case on dbt 2.0.11:

- **A test with two parents can read each parent from a different environment.** `dbt build --select fct_orders --defer --favor-state --state prod-state` builds `fct_orders` in dev. Its `relationships` test then joins dev `fct_orders` to prod `dim_customers`, and passes.
- **That pass can be wrong.** If the PR also changes `dim_customers`, the test checks the dev child against the old prod parent. Here the PR drops customer 4. The test passes locally, and fails as soon as both models come from the PR.
- **`dbt test --favor-state` doesn't test dev at all.** `dbt test` selects only tests, so both parents resolve to prod. The test passes on prod data while Alice's dev table goes unchecked.
- **dbt 2.0.11 doesn't defer a ref just because its dev relation is missing.** It defers unselected refs only with `--favor-state`. dbt-core 1.x defers whenever the dev relation is missing, as the docs describe.
- **Ephemeral models are never deferred.** Their SQL is inlined from the current code, even with `--favor-state`.

Diagnose before you trust a deferred test: open the compiled test in `target/compiled/` and check which schema each side of the join reads from. See [Diagnose it](#diagnose-it).

This branch uses the same dbt v2 and uv setup as [`slim_ci_state_modified`](https://github.com/stanislawbartkowski/dbt_samples/tree/slim_ci_state_modified), with two Spark targets (through Spark Connect, with Delta Lake): `prod` and `dev`. See [Setup](#setup) below.

## The problem

A common explanation goes like this:

> `--defer` requires a `--state` manifest from a prior invocation. When enabled, dbt resolves any unselected `ref()` to the deferred manifest's relation instead of your local target — but only if the referenced node isn't among your currently selected nodes and doesn't already exist as a built object locally (or `--favor-state` forces state priority regardless). Ephemeral models are never deferred, since they have no independent database object.
>
> The subtle risk: run `dbt test --select model_b --defer --state prod-artifacts` where `model_b` has a relationships test against `model_a`, and `model_a` wasn't selected/built locally. dbt resolves `model_a`'s side of the test to the production relation while `model_b`'s side reads from your local dev schema. The test executes as a cross-environment join with no error.

The risk is real. The details depend on the dbt version and on the command:

- **The cross-environment join happens.** It needs `dbt build` (or `dbt run`), which selects the model, and `--favor-state` on dbt 2.0.11.
- **The rule "defer if it doesn't exist locally" is dbt-core 1.x.** dbt 2.0.11 resolved the missing dev relation to dev and failed with `TABLE_OR_VIEW_NOT_FOUND`.
- **`dbt test --select model_b` doesn't select `model_b`.** It selects `model_b`'s tests. With `--favor-state`, both sides of the test read prod, so the test says nothing about dev.
- **A cross-environment test isn't always wrong.** Slim CI depends on it: a deferred parent that the PR doesn't change has the same code in prod, so the test gives the right answer.

## The example

```
customers ── stg_customers ── dim_customers
                                   │  relationships: fct_orders.customer_id
orders ───── stg_orders ───── fct_orders    → dim_customers.customer_id
             (ephemeral)
```

`fct_orders.customer_id` has a `relationships` test against `dim_customers.customer_id` (`models/marts/marts.yml`). The test has two parents, `fct_orders` and `dim_customers`, which aren't upstream of each other.

The prod job builds everything in `defer_prod` and keeps its artifacts in `prod-state/`. Alice works in `defer_dev_alice`. Her PR excludes an internal test account from `dim_customers`:

```sql
select
    customer_id,
    first_name || ' ' || last_name as full_name
from {{ ref('stg_customers') }}
where customer_id <> 4
```

Customer 4 has an order (`seeds/orders.csv`), so with the PR applied, `fct_orders` has one orphan row and the `relationships` test should fail.

`slim_defer_demo.sh` runs every scenario in a scratch copy of the project, so the repo isn't changed. It does write to Spark: it rebuilds `defer_prod` and drops and rebuilds `defer_dev_alice` for each scenario.

## Results

| # | Command, dev schema empty | `fct_orders` side | `dim_customers` side | Result |
| --- | --- | --- | --- | --- |
| 1 | `build --select fct_orders --defer` | dev | not reached | **error**: `fct_orders` reads `defer_dev_alice.orders`, which doesn't exist |
| 1 | `build --select fct_orders --defer --favor-state` | dev | **prod** | pass |
| 2 | Same, with the PR | dev | **prod**, without the PR's change | **pass, wrong** |
| 2 | `build --select state:modified+ --defer --favor-state`, with the PR | **prod**, unchanged | dev | fail, 1 row: correct |
| 3 | `test --select fct_orders --defer --favor-state`, `fct_orders` built in dev | **prod** | **prod** | pass, but dev isn't tested |
| 3 | `test --select fct_orders --defer` | dev | dev | **error**: `dim_customers` doesn't exist in dev |
| 4 | `compile --select fct_orders dim_customers --defer --favor-state`, PR edits `stg_orders` and `stg_customers` | `stg_orders` inlined from the PR | `stg_customers` from prod; the PR's edit is ignored | n/a |

Tested on Spark 4.2.0 with Delta Lake 4.4.1. On Postgres, dbt 2.0.11 resolved the refs in rows 1 and 3 the same way.

For comparison, dbt-core 1.10.23 on Postgres ran row 1 without `--favor-state`: it deferred `fct_orders`'s missing upstream relation to prod, and the test joined dev `fct_orders` to prod `dim_customers` and passed. That is the rule in the docs: an unselected ref is deferred when its dev relation doesn't exist.

The compiled test from row 1 with `--favor-state` (`target/compiled/dbt_utils_demo/target/generic_tests/relationships_fct_orders_*.sql`):

```sql
with child as (
    select customer_id as from_field
    from `defer_dev_alice`.`fct_orders`
    where customer_id is not null
),

parent as (
    select customer_id as to_field
    from `defer_prod`.`dim_customers`
)

select
    from_field

from child
left join parent
    on child.from_field = parent.to_field

where parent.to_field is null
```

### Reproduce it

```bash
source .venv/bin/activate
set -a; source env_standard; set +a
export DBT_PROFILES_DIR=.
dbt deps
./slim_defer_demo.sh
```

It takes about two minutes:

```
== 1. Build one model with --defer, dev schema empty
  $ dbt build --select fct_orders --defer --state prod-state
    Failed model defer_dev_alice.fct_orders
    Skipped test  relationships_fct_orders_customer_id
    error: The table or view `defer_dev_alice`.`orders` cannot be found
    fct_orders reads defer_dev_alice.orders
  With --favor-state:
  $ dbt build --select fct_orders --defer --favor-state --state prod-state
    Succeeded model defer_dev_alice.fct_orders
    Passed test  relationships_fct_orders_customer_id
    fct_orders reads defer_prod.orders
    the test reads defer_dev_alice.fct_orders
    the test reads defer_prod.dim_customers

== 2. The PR drops customer 4 from dim_customers; Alice builds only fct_orders
  $ dbt build --select fct_orders --defer --favor-state --state prod-state
    Succeeded model defer_dev_alice.fct_orders
    Passed test  relationships_fct_orders_customer_id
    the test reads defer_dev_alice.fct_orders
    the test reads defer_prod.dim_customers
  The same PR in Slim CI. fct_orders isn't downstream of dim_customers, so only
  dim_customers is built; the test still runs, against prod's fct_orders:
  $ dbt build --select state:modified+ --defer --favor-state --state prod-state
    Succeeded model defer_dev_alice.dim_customers
    Passed test  not_null_dim_customers_customer_id
    Passed test  unique_dim_customers_customer_id
    Failed test  relationships_fct_orders_customer_id
    Test failed (1 failed row(s))
    the test reads defer_dev_alice.dim_customers
    the test reads defer_prod.fct_orders

== 3. dbt test, not dbt build, with --favor-state
    defer_dev_alice.fct_orders built
  $ dbt test --select fct_orders --defer --favor-state --state prod-state
    Passed test  relationships_fct_orders_customer_id
    the test reads defer_prod.dim_customers
    the test reads defer_prod.fct_orders
  Without --favor-state (dim_customers not in dev):
  $ dbt test --select fct_orders --defer --state prod-state
    Failed test  relationships_fct_orders_customer_id
    error: The table or view `defer_dev_alice`.`dim_customers` cannot be found
    the test reads defer_dev_alice.dim_customers
    the test reads defer_dev_alice.fct_orders

== 4. Ephemeral models are never deferred
  The PR edits two unselected models: stg_orders (ephemeral) and stg_customers (view).
  $ dbt compile --select fct_orders dim_customers --defer --favor-state --state prod-state
    fct_orders reads defer_prod.orders
    fct_orders inlines the PR's stg_orders (amount * 100)
    dim_customers reads defer_prod.stg_customers
    defer_prod.stg_customers is prod's code: the PR's upper(last_name) isn't used
```

### Run it by hand

```bash
# Prod job: build, keep the artifacts outside target/
dbt build --target prod --target-path prod-state

# Alice: start from an empty dev schema, apply the PR
dbt run-operation drop_target_schema
sed -i 's/^from.*/&\nwhere customer_id <> 4/' models/marts/dim_customers.sql

# Build only fct_orders: the test passes, against prod's dim_customers
dbt build --select fct_orders --defer --favor-state --state prod-state

# Build what the PR changed: the test fails, 1 orphan row
dbt build --select state:modified+ --defer --favor-state --state prod-state

# Undo the change
git checkout models/marts/dim_customers.sql
```

On open-source Spark, dbt 2.0.11 also warns `relation_cache: listing schema ... failed` with `REQUIRES_SINGLE_PART_NAMESPACE`. It fills its relation cache by querying `system.information_schema.tables`, which exists only on Databricks. The warning is harmless. It doesn't cause the missing deferral: dbt 2.0.11 on Postgres, where the cache works, resolves to dev the same way.

## Why it happens

dbt resolves every `ref()` once per invocation. With `--defer` and `--state`, each node is resolved like this:

| Node | Resolves to |
| --- | --- |
| Selected, such as the model you build | The target (dev) |
| Unselected, with `--favor-state` | The `--state` manifest's relation (prod) |
| Unselected, without `--favor-state` | dbt-core 1.x: prod if the dev relation doesn't exist, otherwise dev. dbt 2.0.11: dev |
| Ephemeral, selected or not | Never deferred: its SQL is inlined, from the current code, and *its* refs are resolved by these rules |

A generic test resolves its own `ref()`s by the same rules. **Running a test doesn't select the models it tests.** With `dbt build --select fct_orders`, `fct_orders` is selected and `dim_customers` isn't, so the test reads one from dev and one from prod. With `dbt test --select fct_orders`, only the test is selected, so with `--favor-state` both models resolve to prod.

dbt doesn't check that a test's parents come from the same environment. The SQL runs because both schemas are in the same catalog, so nothing fails.

**When a cross-environment test is right.** A deferred parent stands in for what the PR would build. That's true only when the PR doesn't change it, or anything upstream of it. In Slim CI, `state:modified+` selects every changed model and everything downstream, so the deferred parents are unchanged: in scenario 2, prod's `fct_orders` is what the PR would build, and the test is right to fail. When you select models by hand, a changed parent can stay deferred: in scenario 2, the test compares the PR's `fct_orders` with prod's `dim_customers`, which still has customer 4.

The data still differs between environments. A deferred parent holds prod's current data, while the dev side holds whatever was loaded or built when Alice ran it. If dev uses sampled or older data, a test across the two can fail or pass for reasons the code doesn't explain.

**Ephemeral models.** An ephemeral model has no relation, so there is nothing in prod to defer to. dbt inlines its SQL as a CTE from the current code, PR changes included, and defers its refs instead: `fct_orders` inlines the PR's `stg_orders`, which reads `defer_prod.orders`.

## Diagnose it

Check which schema each side of a test reads from:

```bash
grep -h -E 'from ' target/compiled/dbt_utils_demo/target/generic_tests/relationships_*.sql
```

| What you see | Meaning |
| --- | --- |
| Both sides read dev | The test checks dev only |
| Both sides read prod | The test checks prod only; your dev changes aren't tested (`dbt test --favor-state`) |
| One side dev, one side prod | A cross-environment test. Correct only if the PR doesn't change the prod side's model or anything upstream of it |
| `TABLE_OR_VIEW_NOT_FOUND` on a dev relation, with `--defer` | dbt 2.0.11 didn't defer the missing relation; add `--favor-state` or build it |

To check whether the prod side is unchanged, list what the PR modifies:

```bash
dbt ls --select state:modified+ --state prod-state --resource-type model
```

If a model on the prod side of the test is in this list, the test result doesn't describe the PR.

## What to do

- **Use `dbt build`, not `dbt test`, to test a model with `--defer`.** `dbt build --select fct_orders` reads `fct_orders` from dev; `dbt test --select fct_orders --favor-state` reads it from prod.
- **Build every model the PR changes before you trust a test with two parents.** Select `state:modified+` rather than one model by hand. Then every deferred parent is unchanged, and a cross-environment result is meaningful.
- **Pass `--favor-state` with `--defer` on dbt 2.0.11.** Without it, dbt 2.0.11 resolves a missing dev relation to dev and fails. dbt-core 1.x doesn't need it for missing relations.
- **Know that `--favor-state` also skips stale dev objects.** An unselected model resolves to prod even if an old copy exists in dev. Without it on dbt-core 1.x, that old dev copy is used.
- **For a referential check you have to trust, build both sides.** `dbt build --select dim_customers fct_orders --defer --favor-state --state prod-state` runs the test entirely on dev. Or exclude the test from deferred runs and run it after the merge, on prod.

## Setup

1. **Install dbt v2.** It is pinned in `pyproject.toml`:

   ```bash
   uv sync
   uv run dbt --version   # dbt 2.0.11
   ```

2. **Check `profiles.yml`.** It is included and has two Spark Connect outputs, `prod` and `dev`, in different schemas. `dev` is the default target:

   ```yaml
   dbt_utils_demo:
     outputs:
       prod:
         type: spark
         method: spark-connect
         host: localhost
         port: 15002
         schema: defer_prod
         threads: 1
       dev:
         type: spark
         method: spark-connect
         host: localhost
         port: 15002
         schema: defer_dev_alice
         threads: 1
     target: dev
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
| `The table or view ... cannot be found` for a `defer_dev_alice` relation, with `--defer` | dbt 2.0.11 didn't defer the missing relation; add `--favor-state` |
| `Failed to load manifest.json from state path` | No `manifest.json` in the `--state` directory; run the prod job first |
| `prod build failed` from `slim_defer_demo.sh` | Run `dbt build --target prod` directly to see the error; usually `env_standard` isn't loaded or `DBT_PROFILES_DIR` isn't set |
| `The 'spark' adapter is not yet supported` | `env_standard` isn't loaded; see [Environment variables](#environment-variables) |
| `Could not find profile named 'dbt_utils_demo'` | Pass `--profiles-dir .` or set `DBT_PROFILES_DIR` |

## Notes

- **`--favor-state` isn't listed in `dbt build --help` on dbt 2.0.11**, but it is accepted and works.
- **Keep the `--state` directory outside `target/`.** It is the manifest that deferred refs point at; see [`slim_ci_state_modified`](https://github.com/stanislawbartkowski/dbt_samples/tree/slim_ci_state_modified).

## Project layout

| Path | Purpose |
| --- | --- |
| `slim_defer_demo.sh` | Runs every scenario in a scratch copy of the project and prints which schema each node and test reads |
| `macros/drop_target_schema.sql` | `dbt run-operation drop_target_schema`: drops the target's schema, so a scenario starts from an empty dev schema |
| `models/staging/stg_customers.sql` | Staging view over the `customers` seed |
| `models/staging/stg_orders.sql` | Ephemeral staging model over the `orders` seed |
| `models/marts/dim_customers.sql`, `fct_orders.sql` | Delta tables; the two parents of the test |
| `models/marts/marts.yml` | The `relationships` test from `fct_orders` to `dim_customers`, and key tests on `dim_customers` |
| `seeds/orders.csv`, `seeds/customers.csv` | Sample data (types pinned in `dbt_project.yml`); customer 4 has one order |
| `dbt_project.yml` | Marts are Delta tables, the rest views |
| `packages.yml` | dbt package dependencies (`dbt-labs/dbt_utils` 1.x) |
| `pyproject.toml` / `uv.lock` | Python environment; pins `dbt==2.0.11` |
| `env_standard` | Environment variables the project needs (see above) |
| `profiles.yml` | Connections: `prod` and `dev` (default) on Spark Connect at `localhost:15002`, schemas `defer_prod` and `defer_dev_alice` |

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
