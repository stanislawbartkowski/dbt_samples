# dbt_samples

Small, self-contained dbt examples. Each example is a complete dbt project on its own branch. The `main` branch holds only this overview.

## Examples

| Branch | What it shows |
| --- | --- |
| [`concat_macro_overrides`](https://github.com/stanislawbartkowski/dbt_samples/tree/concat_macro_overrides) | How to override a built-in dbt macro. The project replaces `dbt.concat` with its own `postgres__concat`, which joins fields with `' - '`, so `first_name`, `last_name` becomes `John - Doe`. The example runs on dbt v2 and Postgres, and is set up with uv. |

## Using an example

```bash
git clone -b concat_macro_overrides https://github.com/stanislawbartkowski/dbt_samples.git
cd dbt_samples
```

Then follow the README on that branch for setup and commands.
