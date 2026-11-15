#!/usr/bin/env bash
# Shows how `--defer` resolves each ref() in a model and in a relationships
# test, and when the test compares dev data with prod data. Runs in a scratch
# copy of the project, so the repo isn't changed. Builds the prod schema and
# rebuilds the dev schema from scratch for each scenario.
#
#   source .venv/bin/activate; set -a; source env_standard; set +a
#   ./slim_defer_demo.sh
set -uo pipefail

DBT=dbt
SRC=$(cd "$(dirname "$0")" && pwd)
export DBT_PROFILES_DIR=${DBT_PROFILES_DIR:-$SRC}
case $DBT_PROFILES_DIR in /*) ;; *) DBT_PROFILES_DIR=$SRC/$DBT_PROFILES_DIR ;; esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/project"
(cd "$SRC" && cp -r dbt_project.yml packages.yml macros models seeds "$WORK/project/")
[ -d "$SRC/dbt_packages" ] && cp -r "$SRC/dbt_packages" "$WORK/project/"
cd "$WORK/project"

TEST=relationships_fct_orders

# Runs dbt quietly; prints the lines that say what happened to each node.
run() {
    echo "  \$ dbt $*"
    $DBT "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -oE '^ *(Succeeded|Failed|Passed|Skipped) +(model|test) +[a-z_.]+|Test failed \([0-9]+ failed row|The table or view `[^ ]+ cannot be found' \
        | sed -E 's/^ *//; s/__customer_id__ref_dim_customers_//; s/^(Test failed.*)/\1(s))/; s/^(The table.*)/error: \1/; s/^/    /' \
        | awk '!seen[$0]++'
}

# Prints the relations a compiled node reads from.
reads() {
    local file
    file=$(find target/compiled -name "$1*.sql" | head -1)
    [ -n "$file" ] || { echo "    (not compiled)"; return; }
    grep -oE '`[a-z_]+`\.`[a-z_]+`' "$file" | tr -d '`' | sort -u | sed "s/^/    $2 reads /"
}

fresh_dev() { $DBT run-operation drop_target_schema --target dev >/dev/null 2>&1; rm -rf target; }

# The PR: "exclude the internal test account" from dim_customers.
pr_change() {
    sed -i 's/^from.*/&\nwhere customer_id <> 4/' models/marts/dim_customers.sql
}

echo "dbt $($DBT --version 2>&1 | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+')"

echo
echo "== Prod job: build everything, keep the artifacts in prod-state/"
$DBT run-operation drop_target_schema --target prod >/dev/null 2>&1
$DBT build --target prod --target-path prod-state >/dev/null 2>&1 || { echo "prod build failed"; exit 1; }
echo "    defer_prod: customers, orders, stg_customers, dim_customers, fct_orders"

echo
echo "== 1. Build one model with --defer, dev schema empty"
fresh_dev
run build --select fct_orders --defer --state prod-state
reads fct_orders fct_orders
echo "  With --favor-state:"
fresh_dev
run build --select fct_orders --defer --favor-state --state prod-state
reads fct_orders fct_orders
reads "$TEST" "the test"

echo
echo "== 2. The PR drops customer 4 from dim_customers; Alice builds only fct_orders"
fresh_dev; pr_change
run build --select fct_orders --defer --favor-state --state prod-state
reads "$TEST" "the test"
echo "  The same PR in Slim CI. fct_orders isn't downstream of dim_customers, so only"
echo "  dim_customers is built; the test still runs, against prod's fct_orders:"
fresh_dev
run build --select state:modified+ --defer --favor-state --state prod-state
reads "$TEST" "the test"
cp "$SRC/models/marts/dim_customers.sql" models/marts/dim_customers.sql

echo
echo "== 3. dbt test, not dbt build, with --favor-state"
fresh_dev
$DBT build --select fct_orders --defer --favor-state --state prod-state >/dev/null 2>&1
echo "    defer_dev_alice.fct_orders built"
run test --select fct_orders --defer --favor-state --state prod-state
reads "$TEST" "the test"
echo "  Without --favor-state (dim_customers not in dev):"
run test --select fct_orders --defer --state prod-state
reads "$TEST" "the test"

echo
echo "== 4. Ephemeral models are never deferred"
echo "  The PR edits two unselected models: stg_orders (ephemeral) and stg_customers (view)."
sed -i 's/^    amount$/    amount * 100 as amount/' models/staging/stg_orders.sql
sed -i 's/^    last_name$/    upper(last_name) as last_name/' models/staging/stg_customers.sql
rm -rf target
$DBT compile --select fct_orders dim_customers --defer --favor-state --state prod-state >/dev/null 2>&1
echo "  \$ dbt compile --select fct_orders dim_customers --defer --favor-state --state prod-state"
reads fct_orders fct_orders
grep -q 'amount \* 100' target/compiled/dbt_utils_demo/models/marts/fct_orders.sql \
    && echo "    fct_orders inlines the PR's stg_orders (amount * 100)"
reads dim_customers dim_customers
grep -q 'upper(last_name)' prod-state/compiled/dbt_utils_demo/models/staging/stg_customers.sql \
    || echo "    defer_prod.stg_customers is prod's code: the PR's upper(last_name) isn't used"
