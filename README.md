# dbt_samples

Small, self-contained dbt examples. Each example is a complete dbt project on its own branch. The `main` branch holds only this overview.

## Examples

| Branch | What it shows |
| --- | --- |
| [`concat_macro_overrides`](https://github.com/stanislawbartkowski/dbt_samples/tree/concat_macro_overrides) | How to override a built-in dbt macro. The project replaces `dbt.concat` with its own `postgres__concat`, which joins fields with `' - '`, so `first_name`, `last_name` becomes `John - Doe`. The example runs on dbt v2 and Postgres, and is set up with uv. |
| [`jinja_whitespace_control`](https://github.com/stanislawbartkowski/dbt_samples/tree/jinja_whitespace_control) | How Jinja whitespace control breaks compiled SQL. It covers a stray comma that only appears in CI (inside a `{% for %}` loop with an `{% if %}`), tokens glued together by too much `-` stripping, and a `--` comment that silently swallows a column. Each broken model has a fixed version. |
| [`execute_guard_side_effects`](https://github.com/stanislawbartkowski/dbt_samples/tree/execute_guard_side_effects) | Why `{% if execute %}` doesn't prevent side effects. A `DELETE` in a macro still runs during `dbt compile`, `dbt docs generate` and `dbt show`. Fixed by limiting it to `flags.WHICH in ['run', 'build']`. |

## Using an example

```bash
git clone -b concat_macro_overrides https://github.com/stanislawbartkowski/dbt_samples.git
cd dbt_samples
```

Then follow the README on that branch for setup and commands.
