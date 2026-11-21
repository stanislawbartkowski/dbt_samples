# dbt_utils_demo: a Slim CI pipeline on GitHub Actions, stage by stage

This branch builds a Slim CI pipeline for dbt Core on GitHub Actions and checks each step of a common four-stage story about how such pipelines evolve. It runs every case on dbt 2.0.11, and the config-location step on every dbt-core release from 0.19 to 1.12:

- **Each stage cuts CI cost.** On this project, one PR's CI run took 34s as a full rebuild with tables, 7s with views in CI, and 3s with Slim CI (`state:modified+`).
- **Stage four was real, and lasted longer than the story suggests.** A target-aware `materialized` in a model's `config()` block looked modified on every PR on every dbt-core release up to 1.11, unless you set `state_modified_compare_more_unrendered_values` (1.9+). Properties YAML did the same from 1.3. `dbt_project.yml` never did. On dbt-core 1.12 and dbt 2.0.11, none of the three does.
- **The command from the story fails in a fresh per-PR schema on dbt 2.0.11.** `dbt build --select state:modified+ --defer --state prod-state` doesn't defer missing refs to prod and fails with `TABLE_OR_VIEW_NOT_FOUND`. Add `--favor-state`.
- **A shared CI schema breaks concurrent PRs.** Two PRs that both change `fct_orders` and run CI at the same time failed in 3 of 3 runs, each time one of them with an error from the other's change. With one schema per PR, both passed every time.
- **The prod manifest must be downloaded, current and kept outside `target/`.** Without it, `state:modified` fails. With one from before the latest merge to main, CI also rebuilds what that merge changed.

The pipeline is in [`.github/workflows/`](.github/workflows/) and [`ci/`](ci/). See [The pipeline](#the-pipeline).

This branch uses the same dbt v2 and uv setup as [`defer_cross_env_tests`](https://github.com/stanislawbartkowski/dbt_samples/tree/defer_cross_env_tests), with two Spark targets (through Spark Connect, with Delta Lake): `prod` and `ci`. See [Setup](#setup) below.

## The problem

> Design a Slim CI pipeline from first principles for a 1,000-model project on GitHub Actions. Where does the "target-aware config" optimization fit historically?

A common answer goes like this:

> dbt Labs' own case study documents four stages, each removing a specific inefficiency. Stage one: full rebuild on every PR — fine for tiny projects, doesn't scale past 50-minute CI runs. Stage two: target-aware materialization, making expensive models view in CI and table in prod via config branching on target.name.
>
> ```yaml
> models:
>   my_project:
>     marts:
>       +materialized: "{{ 'table' if target.name == 'prod' else 'view' }}"
> ```
>
> Stage three: Slim CI via state:modified, comparing the branch manifest against a deferred production manifest so only changed nodes and their descendants build. Stage four, the catch: stages two and three combined made state comparison flag "modified" on every model with environment-conditional config, on every PR, because the rendered value legitimately differs even though nothing changed. Moving that logic into dbt_project.yml, where the unrendered Jinja string is what's stored and compared, fixed this — reported as a 2.5x to 10x cumulative CI speedup in the original case study.
>
> ```bash
> dbt build --select "state:modified+" --defer --state ./prod-artifacts
> ```
>
> The load-bearing infra pieces: a dedicated CI-only schema per PR to avoid collisions between concurrent PRs; artifact storage for the production manifest accessible to CI runners, since dbt Core on GitHub Actions needs an explicit step to pull last-successful-run artifacts; and --defer wired to the same state path so unselected upstream refs resolve to prod rather than erroring on missing dev objects.

Most of it holds:

- **The stages and the numbers match the source.** It is the dbt Discourse post [How we sped up our CI runs by 10x using Slim CI](https://discourse.getdbt.com/t/how-we-sped-up-our-ci-runs-by-10x-using-slim-ci/2603) (June 2021). CI runs had grown past 50 minutes; Slim CI cut them to 20 (2.5x); moving the target-aware config to `dbt_project.yml` cut them to 5 (10x, compared with before Slim CI).
- **The infrastructure pieces are load-bearing.** Without a per-PR schema, concurrent PRs broke each other's runs. Without the prod manifest, Slim CI can't run.
- **`dbt_project.yml` is the safe place for target-aware config,** on every dbt version tested.

Some details don't:

- **It isn't dbt Labs' case study, and it isn't GitHub Actions.** The author wrote it as Head of Data at Education Perfect, before joining dbt Labs. They used dbt Cloud, which added `--defer`, `--state` and a schema per PR for them. On GitHub Actions you build each of those yourself, as this branch does.
- **The post's config was in a `config()` block, and it ran dbt 0.19.** Its Jinja is only in a screenshot, so the text doesn't confirm that it branched on `target.name`.
- **Stage four isn't history yet.** `config()` kept the problem through dbt-core 1.11 unless you set the flag. dbt-core 1.12 turns the flag on by default, and dbt 2.0.11 doesn't have the problem at all.
- **The command needs `--favor-state` on dbt 2.0.11.** Without it, refs to models that the PR doesn't build resolve to the empty PR schema, and the build fails. dbt-core 1.x defers missing relations without it.

## The pipeline

```
push to main ──► dbt prod (.github/workflows/dbt_prod.yml)
                   ci/prod_deploy.sh: dbt build --target prod
                   upload target/manifest.json as artifact "prod-manifest"
                   (only if the build succeeded)
                              │
pull request ──► dbt slim ci (.github/workflows/dbt_slim_ci.yml)
                   gh run list: last successful dbt prod run on main
                   gh run download: its manifest into prod-state/
                   ci/slim_ci.sh: DBT_CI_SCHEMA=slim_gha_pr_<number>
                     dbt build --select state:modified+ --defer --favor-state --state prod-state
PR closed     ──►  ci/drop_pr_schema.sh: drop slim_gha_pr_<number>
```

| Piece | Where | Why |
| --- | --- | --- |
| Target-aware materialization | `dbt_project.yml` | Marts are tables in prod and views in CI. Set in `dbt_project.yml` so no dbt version flags it as modified |
| Prod manifest as an artifact | `dbt_prod.yml` | GitHub Actions keeps no state between workflows. Uploaded only after a successful build |
| Download the last successful run's manifest | `dbt_slim_ci.yml` | `gh run list --status success` finds the run; the job fails if there is none |
| `prod-state/`, never `target/` | `ci/slim_ci.sh` | Every dbt command overwrites `target/manifest.json`; see [`slim_ci_state_modified`](https://github.com/stanislawbartkowski/dbt_samples/tree/slim_ci_state_modified) |
| One schema per PR | `profiles.yml`, `ci/slim_ci.sh` | The `ci` target's schema is `env_var('DBT_CI_SCHEMA')`; the script sets it to `slim_gha_pr_<number>` |
| One run per PR at a time | `dbt_slim_ci.yml` | `concurrency` cancels the run for an older commit of the same PR, which would write to the same schema |
| `--defer --favor-state` | `ci/slim_ci.sh` | Refs to unchanged models resolve to prod |
| `dbt build`, not `dbt run` then `dbt test` | `ci/slim_ci.sh` | With `--favor-state`, `dbt test` reads every model it doesn't select from prod; see [`defer_cross_env_tests`](https://github.com/stanislawbartkowski/dbt_samples/tree/defer_cross_env_tests) |
| Drop the PR schema | `dbt_slim_ci.yml`, `ci/drop_pr_schema.sh` | Runs when the PR is closed or merged |

The workflows read the Spark Connect host from the `SPARK_CONNECT_HOST` repository secret. They pass [actionlint](https://github.com/rhysd/actionlint), and the scripts they call run locally (see [Results](#results)), but the workflows haven't run on GitHub: that needs a Spark Connect server that GitHub's runners can reach.

## The example

```
customers ── stg_customers ── dim_customers ──┐
                                              ├── customer_revenue
orders ───── stg_orders ───── fct_orders ─────┘
```

Seeds and staging models are tables and views in both environments. The three marts are Delta tables in prod (`slim_gha_prod`) and views in CI, from one line in `dbt_project.yml`:

```yaml
models:
  dbt_utils_demo:
    marts:
      +materialized: "{{ 'table' if target.name == 'prod' else 'view' }}"
```

The PR in most scenarios adds one column to `fct_orders`:

```sql
select
    order_id,
    customer_id,
    amount,
    amount * 100 as amount_cents
from {{ ref('stg_orders') }}
```

`slim_ci_pipeline_demo.sh` runs every scenario in scratch copies of the project, so the repo isn't changed. It does write to Spark: it rebuilds `slim_gha_prod` and drops and rebuilds the CI schemas. `config_location_history.sh` runs stage four on each dbt version; it only parses.

## Results

### Stages one to three: the cost of one PR's CI run

| Stage | Command | Nodes | Time |
| --- | --- | --- | --- |
| 1. Full rebuild, marts are tables | `dbt build` | 11 | 33.8s |
| 2. Full rebuild, marts are views in CI | `dbt build` | 11 | 7.0s |
| 3. Slim CI | `dbt build --select state:modified+ --defer --favor-state --state prod-state` | 4 | 3.4s |

Each run starts from an empty PR schema. The 4 nodes in stage three are `fct_orders`, `customer_revenue` (downstream of it) and their two tests. On Spark, a Delta table took 15–30 seconds to build and a view under a second.

### Stage four: target-aware config with no change

Each model sets `materialized: "{{ 'table' if target.name == 'prod' else 'view' }}"` in a different place. The prod manifest is written with `--target prod`, then `state:modified` is listed with `--target ci`. Nothing else changes, so the right answer is nothing.

| dbt | `state_modified_compare_more_unrendered_values` | `dbt_project.yml` | `config()` | properties YAML |
| --- | --- | --- | --- | --- |
| 0.19.2 – 1.2.7 | n/a | not modified | **modified** | not modified |
| 1.3.8 – 1.8.10 | n/a | not modified | **modified** | **modified** |
| 1.9.11 – 1.11.17 | unset or `false` | not modified | **modified** | **modified** |
| 1.9.11 – 1.11.17 | `true` | not modified | not modified | not modified |
| 1.12.7 | unset or `true` | not modified | not modified | not modified |
| 1.12.7 | `false` | not modified | **modified** | **modified** |
| 2.0.11 | any | not modified | not modified | not modified |

Every minor release in each range was tested: 0.19, 0.20, 0.21, then 1.0 to 1.12. dbt-core ran with the Postgres adapter; dbt 2.0.11 also gave the same result on Spark in `slim_ci_pipeline_demo.sh`.

### The scenario's command, and the infrastructure

| Scenario | Result |
| --- | --- |
| `build --select state:modified+ --defer --state prod-state`, empty PR schema | **error**: `fct_orders` reads `slim_gha_pr_101.stg_orders`, which doesn't exist |
| The same with `--favor-state` | `fct_orders` reads `slim_gha_prod.stg_orders`; 4 of 4 pass |
| Two PRs change `fct_orders` at the same time, one shared CI schema, 3 runs | **One PR fails in every run**, with an error caused by the other PR |
| The same, one schema per PR, 3 runs | Both pass in every run |
| No prod manifest in `prod-state/` | **error**: `Failed to load manifest.json from state path` |
| Prod manifest from before a merge that changed `dim_customers` | `state:modified` selects `dim_customers` and `fct_orders` |
| Prod manifest from after that merge | `state:modified` selects `fct_orders` |

In the shared schema, which PR failed and how depended on timing. Across runs, the failing PR got `TABLE_OR_VIEW_ALREADY_EXISTS` (both ran `create or replace view slim_gha_ci.fct_orders` at once), `TABLE_OR_VIEW_NOT_FOUND`, or `UNRESOLVED_COLUMN` (its `not_null` test on `amount_cents` ran against the other PR's `fct_orders`, which doesn't have it).

Tested on Spark 4.2.0 with Delta Lake 4.4.1.

### Reproduce it

```bash
source .venv/bin/activate
set -a; source env_standard; set +a
export DBT_PROFILES_DIR=.
dbt deps
./slim_ci_pipeline_demo.sh
./config_location_history.sh
```

`slim_ci_pipeline_demo.sh` takes about three minutes:

```
== Prod job: build everything in slim_gha_prod, keep the manifest in prod-state/
    Summary: 11 total | 11 success

== Cost of one PR's CI run, stage by stage (the PR adds a column to fct_orders)
  Stage 1, full rebuild, marts are tables as in prod:
    Summary: 11 total | 11 success             33.8s
  Stage 2, full rebuild, marts are views in CI:
    Summary: 11 total | 11 success              7.0s
  Stage 3, Slim CI: state:modified+ --defer --favor-state, views:
    Summary: 4 total | 4 success                3.4s

== Stage 4: does target-aware config look modified on every PR?
  No change at all. materialized depends on target.name, set in three places:
    dim_customers: dbt_project.yml; fct_orders: config(); customer_revenue: marts.yml
    state:modified -> (nothing)

== The scenario's command, in a fresh PR schema: --defer without --favor-state
  $ dbt build --target ci --select state:modified+ --defer --state prod-state
    Failed model slim_gha_pr_101.fct_orders (view)
    Skipped test  relationships_fct_orders_customer_id__customer_id__ref_dim_customers_
    Skipped model slim_gha_pr_101.customer_revenue (view)
    Skipped test  unique_customer_revenue_customer_id
    error: [TABLE_OR_VIEW_NOT_FOUND] The table or view `slim_gha_pr_101`.
    Summary: 4 total | 1 error | 3 skipped
  With --favor-state:
  $ dbt build --target ci --select state:modified+ --defer --favor-state --state prod-state
    Succeeded model slim_gha_pr_101.fct_orders (view)
    Passed test  relationships_fct_orders_customer_id__customer_id__ref_dim_customers_
    Succeeded model slim_gha_pr_101.customer_revenue (view)
    Passed test  unique_customer_revenue_customer_id
    Summary: 4 total | 4 success

== Two PRs at the same time, one shared CI schema
  PR 101 adds amount_cents to fct_orders, with a not_null test.
  PR 102 adds amount_rounded to fct_orders, with a not_null test.
  dbt build ... --defer --favor-state, both in slim_gha_ci:
    Run 1:
      PR 101: 5 total | 5 success
      PR 102: 5 total | 1 success | 2 error | 2 skipped  <- TABLE_OR_VIEW_NOT_FOUND `slim_gha_ci`.`fct_orders`
    Run 2:
      PR 101: 5 total | 5 success
      PR 102: 5 total | 1 success | 2 error | 2 skipped  <- TABLE_OR_VIEW_NOT_FOUND `slim_gha_ci`.`fct_orders`
    Run 3:
      PR 101: 5 total | 5 success
      PR 102: 5 total | 1 success | 2 error | 2 skipped  <- TABLE_OR_VIEW_NOT_FOUND `slim_gha_ci`.`fct_orders`
  One schema per PR (ci/slim_ci.sh), slim_gha_pr_101 and slim_gha_pr_102:
    Run 1:
      PR 101: 5 total | 5 success
      PR 102: 5 total | 5 success
    Run 2:
      PR 101: 5 total | 5 success
      PR 102: 5 total | 5 success
    Run 3:
      PR 101: 5 total | 5 success
      PR 102: 5 total | 5 success

== The prod manifest artifact
  Not downloaded (prod-state/ is empty):
  $ dbt ls --target ci --select state:modified --state empty-state
    [error] [ManifestLoadFailed (dbt1150)]: Failed to load manifest.json from state path 'empty-state': Failed to read file: empty-state/man
  Stale: a later merge to main changed dim_customers, but its prod run
  hasn't finished, so the newest artifact is from before it:
    state:modified -> dim_customers fct_orders
  After the prod run for that merge:
    state:modified -> fct_orders
```

Times and the shared-schema errors vary from run to run.

`config_location_history.sh` downloads each dbt-core version with uvx on its first run, which takes several minutes. Its output:

```
dbt       flag   state:modified, no change
0.19.2    unset  m_config
...
1.2.7     unset  m_config
1.3.8     unset  m_config m_yaml
...
1.11.17   unset  m_config m_yaml
1.11.17   false  m_config m_yaml
1.11.17   true   (nothing)
1.12.7    unset  (nothing)
1.12.7    false  m_config m_yaml
1.12.7    true   (nothing)
2.0.11    unset  (nothing)
2.0.11    false  (nothing)
2.0.11    true   (nothing)
```

`m_project` sets the config in `dbt_project.yml`, `m_config` in `config()`, and `m_yaml` in properties YAML.

### Run the pipeline by hand

```bash
# Prod job: build, keep the manifest in prod-state/
ci/prod_deploy.sh prod-state

# The PR: add a column to fct_orders
sed -i 's/^    amount$/    amount,\n    amount * 100 as amount_cents/' models/marts/fct_orders.sql

# The CI job for PR 101: builds fct_orders and customer_revenue in slim_gha_pr_101
PR_NUMBER=101 ci/slim_ci.sh prod-state

# The PR is closed: drop its schema, undo the change
PR_NUMBER=101 ci/drop_pr_schema.sh
git checkout models/marts/fct_orders.sql
```

On open-source Spark, dbt 2.0.11 also warns `relation_cache: listing schema ... failed` with `REQUIRES_SINGLE_PART_NAMESPACE`. It fills its relation cache by querying `system.information_schema.tables`, which exists only on Databricks. The warning is harmless.

## Why it happens

**Stages one and two.** A full rebuild builds every node, so CI time grows with the project. Views cost a `create view`; tables also compute and write the data, which on Spark is a Delta write per model. The data stays in prod: CI views read prod's tables through `--defer`, or the seeds in the PR schema in a full rebuild.

**Stage three.** `state:modified` compares each node in the PR's manifest with the same node in the prod manifest, and `+` adds everything downstream. With `--defer --favor-state`, every model the build doesn't select resolves to prod, so nothing upstream is rebuilt.

**Stage four.** `state:modified` compares each node's `unrendered_config` in the manifest, not the config dbt builds with. Despite the name, dbt fills it with the rendered value (`table` in prod, `view` in CI) for some locations, and those differ between the two targets. What the manifest holds for `materialized`:

| dbt | `dbt_project.yml` | `config()` | Properties YAML |
| --- | --- | --- | --- |
| dbt-core 1.2.7 | Jinja text | rendered: `table` | nothing, so not compared |
| dbt-core 1.3.8; 1.11.17 without the flag | Jinja text | rendered: `table` | rendered: `table` |
| dbt-core 1.11.17 with the flag | Jinja text | the parsed Jinja expression | Jinja text |
| dbt 2.0.11 | Jinja text | Jinja text | Jinja text |

So the case study's fix, moving the config to `dbt_project.yml`, works on every version. On dbt-core 1.12 and dbt 2.0.11 it isn't needed.

**`--favor-state` on dbt 2.0.11.** dbt-core 1.x defers a ref when the model isn't selected and its relation doesn't exist in the target schema. dbt 2.0.11 defers unselected refs only with `--favor-state`. A new PR schema is empty, so without it every unbuilt upstream ref points at a relation that doesn't exist.

**The shared schema.** The `ci` target's schema is the same for every PR unless the job changes it. Two jobs that run at once replace the same views and run tests against them. Nothing stops the other job from replacing a view between one job's `create or replace view` and its tests, or from creating it at the same moment.

**The prod manifest.** GitHub Actions jobs start on a fresh runner, so the manifest has to come from somewhere. If it is older than main, every change merged since then looks modified to the PR, because the PR branch contains it and the manifest doesn't.

## What to do

For a 1,000-model project on GitHub Actions:

- **Run one prod workflow on every merge to main, and upload its manifest only after it succeeds.** The Slim CI workflow downloads the manifest from the last successful run with `gh run list --status success`. A failed prod run then doesn't replace a manifest whose relations exist.
- **Fail the CI job when there is no manifest.** A silent fallback to a full build hides the problem, and on 1,000 models costs the full rebuild you set out to avoid. Set the artifact's `retention-days` longer than the longest gap between merges.
- **Download the manifest to its own directory, never `target/`.** See [`slim_ci_state_modified`](https://github.com/stanislawbartkowski/dbt_samples/tree/slim_ci_state_modified).
- **Give each PR its own schema, and drop it when the PR closes.** Also add a `concurrency` group per PR, so two pushes to one PR don't build in the same schema at once.
- **Pass `--defer --favor-state --state prod-state` on dbt 2.0.11.** dbt-core 1.x works without `--favor-state`, but it then uses an old copy of a model in the PR schema instead of prod.
- **Use one `dbt build`.** Separate `dbt run` and `dbt test` steps with `--favor-state` test prod, not the PR.
- **Set target-aware configs in `dbt_project.yml`.** It is never a false positive. On dbt-core 1.9 – 1.11, also set `state_modified_compare_more_unrendered_values: true`, and rebuild the prod manifest after you set it.
- **Expect large PRs to stay expensive.** An edit to a macro that every model calls selects every model; see [`slim_ci_state_modified`](https://github.com/stanislawbartkowski/dbt_samples/tree/slim_ci_state_modified).

## Setup

1. **Install dbt v2.** It is pinned in `pyproject.toml`:

   ```bash
   uv sync
   uv run dbt --version   # dbt 2.0.11
   ```

2. **Check `profiles.yml`.** It is included and has two Spark Connect outputs, `prod` and `ci`. `ci` is the default target, and its schema comes from `DBT_CI_SCHEMA`:

   ```yaml
   dbt_utils_demo:
     outputs:
       prod:
         type: spark
         method: spark-connect
         host: "{{ env_var('SPARK_CONNECT_HOST', 'localhost') }}"
         port: 15002
         schema: slim_gha_prod
         threads: 4
       ci:
         type: spark
         method: spark-connect
         host: "{{ env_var('SPARK_CONNECT_HOST', 'localhost') }}"
         port: 15002
         schema: "{{ env_var('DBT_CI_SCHEMA', 'slim_gha_ci') }}"
         threads: 4
     target: ci
   ```

   Use a plain `host` and `port`, as above. dbt 2.0.9 needed a workaround (`host: "localhost:15002/;user_id=dbt"` without `port`); dbt 2.0.11 rejects it.

3. **Install dbt packages:**

   ```bash
   uv run --env-file env_standard dbt deps --profiles-dir .
   ```

4. **To run the workflows on GitHub,** add a repository secret `SPARK_CONNECT_HOST` with a Spark Connect host that GitHub's runners can reach, and run the `dbt prod` workflow once on main before opening a PR.

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

The CI scripts and `profiles.yml` also read:

| Variable | Used by | Default |
| --- | --- | --- |
| `PR_NUMBER` | `ci/slim_ci.sh`, `ci/drop_pr_schema.sh` | required |
| `DBT_CI_SCHEMA` | `profiles.yml`, `ci` target; set by the CI scripts | `slim_gha_ci` |
| `SPARK_CONNECT_HOST` | `profiles.yml` | `localhost` |

## Troubleshooting

| Error | Fix |
| --- | --- |
| `The table or view ... cannot be found` for a `slim_gha_pr_*` relation | Add `--favor-state`; dbt 2.0.11 doesn't defer missing relations without it |
| `Failed to load manifest.json from state path` | No `manifest.json` in the `--state` directory; run the prod job first |
| `No prod manifest in prod-state/` from `ci/slim_ci.sh` | The same; in GitHub Actions, check that the `dbt prod` workflow has a successful run on main |
| `TABLE_OR_VIEW_ALREADY_EXISTS` on a CI model | Two jobs build in the same schema at once; set `PR_NUMBER` or `DBT_CI_SCHEMA` |
| `prod build failed` from `slim_ci_pipeline_demo.sh` | Run `dbt build --target prod` directly to see the error; usually `env_standard` isn't loaded or `DBT_PROFILES_DIR` isn't set |
| `The 'spark' adapter is not yet supported` | `env_standard` isn't loaded; see [Environment variables](#environment-variables) |
| `Could not find profile named 'dbt_utils_demo'` | Pass `--profiles-dir .` or set `DBT_PROFILES_DIR` |

## Notes

- **The times are from a five-model project.** They show the ratio between stages on this Spark server, not what a 1,000-model project takes.
- **Before dbt-core 1.3, a change to a config in properties YAML wasn't detected at all.** dbt-core 1.2.7 didn't store it unrendered and didn't compare it: changing `materialized: view` to `table` in properties YAML didn't mark the model modified. 1.3.8 did.
- **`--favor-state` isn't listed in `dbt build --help` on dbt 2.0.11**, but it is accepted and works.
- **`dbt parse` doesn't write `manifest.json` before dbt-core 1.5,** so `config_location_history.sh` uses `dbt ls` to write the prod manifest.

## Project layout

| Path | Purpose |
| --- | --- |
| `.github/workflows/dbt_prod.yml` | Prod workflow: builds on every push to main and uploads the manifest |
| `.github/workflows/dbt_slim_ci.yml` | Slim CI workflow: downloads the last successful prod manifest, builds the PR in its own schema, drops the schema when the PR closes |
| `ci/prod_deploy.sh` | `dbt build --target prod`, then copies the manifest |
| `ci/slim_ci.sh` | Checks the manifest, sets the PR schema, runs `dbt build --select state:modified+ --defer --favor-state` |
| `ci/drop_pr_schema.sh` | Drops a PR's schema |
| `slim_ci_pipeline_demo.sh` | Runs every pipeline scenario in scratch copies of the project |
| `config_location_history.sh` | Runs stage four on dbt-core 0.19 to 1.12 and dbt v2 |
| `macros/drop_target_schema.sql` | `dbt run-operation drop_target_schema`: drops the target's schema |
| `models/staging/stg_*.sql` | Staging views over the seeds |
| `models/marts/*.sql` | Marts; Delta tables in prod, views in CI |
| `models/marts/marts.yml` | Key and `relationships` tests on the marts |
| `seeds/orders.csv`, `seeds/customers.csv` | Sample data (types pinned in `dbt_project.yml`) |
| `dbt_project.yml` | The target-aware materialization for the marts, and `file_format: delta` |
| `packages.yml` | dbt package dependencies (`dbt-labs/dbt_utils` 1.x) |
| `pyproject.toml` / `uv.lock` | Python environment; pins `dbt==2.0.11` |
| `env_standard` | Environment variables the project needs (see above) |
| `profiles.yml` | Connections: `prod` and `ci` (default) on Spark Connect, port 15002 |

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
