#!/usr/bin/env bash
# Runs the Slim CI pipeline locally, stage by stage, and checks each claim
# about it. Runs in scratch copies of the project, so the repo isn't changed.
# It does write to Spark: it rebuilds slim_gha_prod and drops and rebuilds
# slim_gha_ci, slim_gha_pr_101 and slim_gha_pr_102.
#
#   source .venv/bin/activate; set -a; source env_standard; set +a
#   ./slim_ci_pipeline_demo.sh
set -uo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
export DBT_PROFILES_DIR=${DBT_PROFILES_DIR:-$SRC}
case $DBT_PROFILES_DIR in /*) ;; *) DBT_PROFILES_DIR=$SRC/$DBT_PROFILES_DIR ;; esac
unset DBT_CI_SCHEMA

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A fresh copy of the project in $WORK/$1, as a CI runner checks it out.
checkout() {
    rm -rf "${WORK:?}/$1"
    mkdir "$WORK/$1"
    (cd "$SRC" && cp -r dbt_project.yml packages.yml macros models seeds ci "$WORK/$1/")
    [ -d "$SRC/dbt_packages" ] && cp -r "$SRC/dbt_packages" "$WORK/$1/"
    # The prod manifest, as the CI job downloads it
    ln -s "$WORK/prod-state" "$WORK/$1/prod-state"
    cd "$WORK/$1" || exit 1
}

# Run dbt and print the result lines, without colors or Spark cache warnings.
run() {
    echo "  \$ dbt $*"
    dbt "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -E '^ *(Succeeded|Failed|Passed|Skipped|Nothing)|TABLE_OR_VIEW_NOT_FOUND|UNRESOLVED_COLUMN|Failed to load|Summary:' \
        | sed -E 's/ \(models\/[^)]*\)//; s/ \[[0-9]+ of [0-9]+.*//; s/.*(\[(TABLE_OR_VIEW_NOT_FOUND|UNRESOLVED_COLUMN[A-Z_.]*)\][^.]*\.).*/error: \1/' \
        | sed 's/^ */    /' | cut -c1-140
}

# Run dbt quietly; print only the elapsed time.
timed() {
    local start end
    start=$(date +%s%N)
    dbt "$@" >"$WORK/last.log" 2>&1 || { echo "    dbt $1 failed; see below"; tail -20 "$WORK/last.log"; }
    end=$(date +%s%N)
    local summary
    summary=$(sed 's/\x1b\[[0-9;]*m//g' "$WORK/last.log" | grep -m1 -oE '^Summary: .*')
    local ds=$(( (end - start) / 100000000 ))
    printf '    %-40s %4d.%ds\n' "${summary:-Summary: nothing}" $((ds / 10)) $((ds % 10))
}

drop_schema() { DBT_CI_SCHEMA=$1 dbt run-operation drop_target_schema --target "${2:-ci}" >/dev/null 2>&1; }

modified() {
    local names
    names=$(dbt ls --quiet --target ci --resource-type model --select state:modified --state "$1" --output name 2>&1 | sort | tr '\n' ' ')
    echo "    state:modified -> ${names:-(nothing)}"
}

# The PR from the scenario: one new column in fct_orders.
pr_change() {
    sed -i 's/^    amount$/    amount,\n    amount * 100 as amount_cents/' models/marts/fct_orders.sql
}

echo "dbt $(dbt --version 2>&1 | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+')"

echo
echo "== Prod job: build everything in slim_gha_prod, keep the manifest in prod-state/"
checkout main
drop_schema slim_gha_prod prod
ci/prod_deploy.sh "$WORK/prod-state" >"$WORK/prod.log" 2>&1 || { echo "prod build failed"; tail -20 "$WORK/prod.log"; exit 1; }
echo "    $(sed 's/\x1b\[[0-9;]*m//g' "$WORK/prod.log" | grep -m1 -oE '^Summary: .*')"

echo
echo "== Cost of one PR's CI run, stage by stage (the PR adds a column to fct_orders)"
echo "  Stage 1, full rebuild, marts are tables as in prod:"
checkout stage1; pr_change
sed -i "s/+materialized: \"{{ 'table' if target.name == 'prod' else 'view' }}\"/+materialized: table/" dbt_project.yml
drop_schema slim_gha_pr_101
DBT_CI_SCHEMA=slim_gha_pr_101 timed build --target ci
echo "  Stage 2, full rebuild, marts are views in CI:"
checkout stage2; pr_change
drop_schema slim_gha_pr_101
DBT_CI_SCHEMA=slim_gha_pr_101 timed build --target ci
echo "  Stage 3, Slim CI: state:modified+ --defer --favor-state, views:"
drop_schema slim_gha_pr_101
DBT_CI_SCHEMA=slim_gha_pr_101 timed build --target ci --select state:modified+ --defer --favor-state --state prod-state

echo
echo "== Stage 4: does target-aware config look modified on every PR?"
echo "  No change at all. materialized depends on target.name, set in three places:"
checkout stage4
sed -i "/+materialized: \"{{ 'table' if target.name == 'prod' else 'view' }}\"/d" dbt_project.yml
sed -i "1i {{ config(materialized='table' if target.name == 'prod' else 'view') }}\n" models/marts/fct_orders.sql
sed -i "s/^  - name: customer_revenue$/&\n    config:\n      materialized: \"{{ 'table' if target.name == 'prod' else 'view' }}\"/" models/marts/marts.yml
sed -i "s/^    marts:$/&\n      dim_customers:\n        +materialized: \"{{ 'table' if target.name == 'prod' else 'view' }}\"/" dbt_project.yml
dbt parse --target prod --target-path "$WORK/stage4-state" >/dev/null 2>&1 || echo "    dbt parse failed"
echo "    dim_customers: dbt_project.yml; fct_orders: config(); customer_revenue: marts.yml"
modified "$WORK/stage4-state"

echo
echo "== The scenario's command, in a fresh PR schema: --defer without --favor-state"
checkout pr101; pr_change
drop_schema slim_gha_pr_101
DBT_CI_SCHEMA=slim_gha_pr_101 run build --target ci --select state:modified+ --defer --state prod-state
echo "  With --favor-state:"
DBT_CI_SCHEMA=slim_gha_pr_101 run build --target ci --select state:modified+ --defer --favor-state --state prod-state

echo
echo "== Two PRs at the same time, one shared CI schema"
echo "  PR 101 adds amount_cents to fct_orders, with a not_null test."
echo "  PR 102 adds amount_rounded to fct_orders, with a not_null test."
checkout pr101; pr_change
sed -i 's/^  - name: customer_revenue$/      - name: amount_cents\n        data_tests:\n          - not_null\n&/' models/marts/marts.yml
checkout pr102
sed -i 's/^    amount$/    amount,\n    round(amount, 0) as amount_rounded/' models/marts/fct_orders.sql
sed -i 's/^  - name: customer_revenue$/      - name: amount_rounded\n        data_tests:\n          - not_null\n&/' models/marts/marts.yml

# Both PRs' CI jobs run dbt build at the same time, in schema $1 and $2.
race() {
    for pr in 101 102; do
        local schema=$1; [ $pr = 102 ] && schema=$2
        (cd "$WORK/pr$pr" && DBT_CI_SCHEMA=$schema dbt build --target ci --select state:modified+ \
            --defer --favor-state --state prod-state >"$WORK/pr$pr.log" 2>&1) &
    done
    wait
    for pr in 101 102; do
        local log summary error
        log=$(sed 's/\x1b\[[0-9;]*m//g' "$WORK/pr$pr.log")
        summary=$(grep -m1 -oE '^Summary: .*' <<<"$log")
        # The error class and the first name it quotes, e.g. UNRESOLVED_COLUMN `amount_cents`
        # shellcheck disable=SC2016
        error=$(grep -m1 -oE '\[(TABLE_OR_VIEW_NOT_FOUND|UNRESOLVED_COLUMN)[A-Z_.]*\] [^`]*(`[a-z_]+`\.?)+' <<<"$log" \
            | sed -E 's/^\[([A-Z_]+)[A-Z_.]*\][^`]*/\1 /')
        [ -z "$error" ] && error=$(grep -m1 -oE '\[error\].*' <<<"$log" | cut -c1-90)
        echo "      PR $pr: ${summary#Summary: }${error:+  <- $error}"
    done
}
echo "  dbt build ... --defer --favor-state, both in slim_gha_ci:"
for i in 1 2 3; do
    drop_schema slim_gha_ci
    echo "    Run $i:"; race slim_gha_ci slim_gha_ci
done
echo "  One schema per PR (ci/slim_ci.sh), slim_gha_pr_101 and slim_gha_pr_102:"
for i in 1 2 3; do
    drop_schema slim_gha_pr_101; drop_schema slim_gha_pr_102
    echo "    Run $i:"; race slim_gha_pr_101 slim_gha_pr_102
done

echo
echo "== The prod manifest artifact"
checkout pr101; pr_change
echo "  Not downloaded (prod-state/ is empty):"
mkdir -p empty-state
run ls --target ci --select state:modified --state empty-state
echo "  Stale: a later merge to main changed dim_customers, but its prod run"
echo "  hasn't finished, so the newest artifact is from before it:"
sed -i "s/first_name || ' ' || last_name/initcap(first_name || ' ' || last_name)/" models/marts/dim_customers.sql
modified prod-state
echo "  After the prod run for that merge:"
checkout main
sed -i "s/first_name || ' ' || last_name/initcap(first_name || ' ' || last_name)/" models/marts/dim_customers.sql
dbt parse --target prod --target-path "$WORK/new-state" >/dev/null 2>&1 || echo "    dbt parse failed"
cd "$WORK/pr101" || exit 1
modified "$WORK/new-state"

# Leave no PR schemas behind.
for schema in slim_gha_ci slim_gha_pr_101 slim_gha_pr_102; do drop_schema $schema; done
