#!/usr/bin/env bash
# Runs every Slim CI scenario in a scratch copy of the project and prints
# which models `state:modified` selects. Nothing in the repo is changed and
# nothing is built: `dbt parse` and `dbt ls` only need the manifest.
#
#   source .venv/bin/activate; set -a; source env_standard; set +a
#   ./slim_ci_demo.sh
set -uo pipefail

DBT=dbt
TARGET_DIR=target
SRC=$(cd "$(dirname "$0")" && pwd)
export DBT_PROFILES_DIR=${DBT_PROFILES_DIR:-$SRC}
case $DBT_PROFILES_DIR in /*) ;; *) DBT_PROFILES_DIR=$SRC/$DBT_PROFILES_DIR ;; esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

reset() {
    rm -rf "$WORK/project"
    mkdir "$WORK/project"
    (cd "$SRC" && cp -r dbt_project.yml packages.yml macros models seeds "$WORK/project/")
    [ -d "$SRC/dbt_packages" ] && cp -r "$SRC/dbt_packages" "$WORK/project/"
    cd "$WORK/project"
}

set_flag() {
    sed -i "s/state_modified_compare_more_unrendered_values: .*/state_modified_compare_more_unrendered_values: $1/" dbt_project.yml
}

# The prod job: parse with the prod target and keep the manifest.
prod_manifest() {
    $DBT parse --target prod --target-path prod-state >/dev/null 2>&1 || { echo "dbt parse failed"; exit 1; }
}

# The CI job: list what Slim CI would build. Prints the model names, or the
# error dbt reports.
modified() {
    local selector=$1 state=$2 out
    out=$($DBT ls --target ci --target-path "$TARGET_DIR" --resource-type model \
        --select "$selector" --state "$state" 2>&1)
    local models
    models=$(grep -oE '^dbt_utils_demo\.[a-z_.]+' <<<"$out" | sed 's/.*\.//' | sort | tr '\n' ' ')
    if [ -n "$models" ]; then
        echo "    $selector -> $models"
    elif grep -qiE 'error' <<<"$out"; then
        echo "    $selector -> ERROR: $(grep -iE 'error' <<<"$out" | head -1 | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-120)"
    else
        echo "    $selector -> (nothing)"
    fi
}

# The one-line change that the PR is about.
one_line_change() {
    sed -i 's/^    amount,$/    amount,\n    amount * 100 as amount_cents,/' models/marts/fct_orders.sql
}

echo "dbt $($DBT --version 2>&1 | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+')"

echo
echo "== Cause 1: --state and --target-path are the same directory"
echo "  The PR changes one line in fct_orders."
reset; set_flag true; prod_manifest; one_line_change
echo "  Separate directories (--state prod-state):"
modified state:modified prod-state
echo "  Prod manifest copied into $TARGET_DIR/, --state $TARGET_DIR:"
rm -rf "$TARGET_DIR"; mkdir "$TARGET_DIR"; cp prod-state/manifest.json "$TARGET_DIR/"
modified state:modified "$TARGET_DIR"
echo "  The next dbt command in the same job, --state $TARGET_DIR:"
modified state:modified "$TARGET_DIR"

echo
echo "== Cause 2: configs that depend on target.name"
echo "  No change at all. fct_orders sets materialized in config(),"
echo "  customer_revenue in marts.yml, dim_customers in dbt_project.yml."
for flag in false true; do
    reset; set_flag $flag; prod_manifest
    echo "  state_modified_compare_more_unrendered_values: $flag"
    modified state:modified prod-state
    modified state:modified.configs prod-state
done

echo
echo "== Cause 3: a comment added inside a shared macro"
reset; set_flag true; prod_manifest
sed -i 's/^{% macro audit_columns() -%}$/{% macro audit_columns() -%}\n    {#- load timestamp, UTC -#}/' macros/audit_columns.sql
modified state:modified prod-state
modified state:modified.body prod-state
modified state:modified.macros prod-state
echo "  The same comment above the {% macro %} block instead:"
reset; set_flag true; prod_manifest
sed -i '1i {#- load timestamp, UTC -#}' macros/audit_columns.sql
modified state:modified prod-state
