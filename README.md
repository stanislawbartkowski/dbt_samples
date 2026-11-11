# dbt_samples

Small, self-contained dbt examples. Each example is a complete dbt project on its own branch. The `main` branch holds only this overview.

## Examples

| Branch | What it shows |
| --- | --- |
| [`concat_macro_overrides`](https://github.com/stanislawbartkowski/dbt_samples/tree/concat_macro_overrides) | How to override a built-in dbt macro. The project replaces `dbt.concat` with its own `postgres__concat`, which joins fields with `' - '`, so `first_name`, `last_name` becomes `John - Doe`. The example runs on dbt v2 and Postgres, and is set up with uv. |
| [`jinja_whitespace_control`](https://github.com/stanislawbartkowski/dbt_samples/tree/jinja_whitespace_control) | How Jinja whitespace control breaks compiled SQL. It covers a stray comma that only appears in CI (inside a `{% for %}` loop with an `{% if %}`), tokens glued together by too much `-` stripping, and a `--` comment that silently swallows a column. Each broken model has a fixed version. |
| [`execute_guard_side_effects`](https://github.com/stanislawbartkowski/dbt_samples/tree/execute_guard_side_effects) | Why `{% if execute %}` doesn't prevent side effects. A `DELETE` in a macro still runs during `dbt compile`, `dbt docs generate` and `dbt show`. Fixed by limiting it to `flags.WHICH in ['run', 'build']`. |
| [`run_query_parse_none`](https://github.com/stanislawbartkowski/dbt_samples/tree/run_query_parse_none) | What `run_query()` returns while dbt parses the project, and why reading its result without an `{% if execute %}` guard breaks `dbt parse`. In dbt 2.0.8 the same model still passes `dbt run`, so the bug can stay hidden until CI runs `dbt parse`. |
| [`run_query_fetch_result`](https://github.com/stanislawbartkowski/dbt_samples/tree/run_query_fetch_result) | Why swapping `statement(..., fetch_result=False)` for `run_query()` in an `OPTIMIZE ... ZORDER BY` post-hook crashes dbt 2.0.9 on Spark with Delta Lake, while dbt-core 1.x runs the same code. Use `run_query()` only when you read the result. |
| [`package_macro_guards`](https://github.com/stanislawbartkowski/dbt_samples/tree/package_macro_guards) | How a package can check for a macro, such as `dbt.date_spine`, before calling it, so users on an older dbt get a clear error or a fallback. Shows that the `dbt.get()` check from the dbt docs always fails on dbt 2.0.9, that `is defined` works everywhere, and that dbt 2.0.9 ignores `require-dbt-version`. |
| [`jinja_loop_scoping`](https://github.com/stanislawbartkowski/dbt_samples/tree/jinja_loop_scoping) | Why a list built with `{% set %}` inside a `{% for %}` loop is empty after the loop. A post-hook records the ids it found as a table property, and the broken version silently records none. Fixed with `namespace()` or `{% do list.append() %}`. Runs on Spark. |
| [`custom_materialization_contracts`](https://github.com/stanislawbartkowski/dbt_samples/tree/custom_materialization_contracts) | Why `contract: {enforced: true}` is silently ignored on a custom materialization that writes its own DDL, while `table` fails on the same contract violation. The fixed materialization calls `get_assert_columns_equivalent` and builds the table with `get_create_table_as_sql`. Runs on Spark with Delta Lake. |
| [`incremental_contract_schema_change`](https://github.com/stanislawbartkowski/dbt_samples/tree/incremental_contract_schema_change) | Which `on_schema_change` values are safe on an incremental model with an enforced contract. dbt rejects `ignore` and `sync_all_columns` at parse time, but `append_new_columns` silently keeps an old column type after the contract changes it. Only `fail` keeps the table in sync; otherwise add a test, such as the included `matches_contract`, that compares the live table with the contract. Runs on Spark with Delta Lake. |

## Using an example

```bash
git clone -b concat_macro_overrides https://github.com/stanislawbartkowski/dbt_samples.git
cd dbt_samples
```

Then follow the README on that branch for setup and commands.
