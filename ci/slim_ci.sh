#!/usr/bin/env bash
# The Slim CI job for one pull request (.github/workflows/dbt_slim_ci.yml).
#
#   PR_NUMBER=123 ci/slim_ci.sh [STATE_DIR]
#
# Builds and tests the models the PR changes, and everything downstream of
# them, in the PR's own schema. Every other ref() resolves to prod.
set -euo pipefail

: "${PR_NUMBER:?Set PR_NUMBER to the pull request number}"
STATE_DIR=${1:-prod-state}

# 1. The prod manifest must be there. Without it, state:modified can't be
#    computed; fail rather than fall back to building everything.
if [ ! -f "$STATE_DIR/manifest.json" ]; then
    echo "::error::No prod manifest in $STATE_DIR/. Download the last successful prod run's manifest first." >&2
    exit 1
fi

# 2. Keep the prod manifest out of the target path. Every dbt command writes
#    target/manifest.json; with --state target, the second command in the job
#    would compare the PR with itself and select nothing.
if [ "$(cd "$STATE_DIR" && pwd)" = "$(pwd)/target" ]; then
    echo "::error::STATE_DIR must not be target/: dbt overwrites target/manifest.json" >&2
    exit 1
fi

# 3. One schema per PR, so concurrent PRs don't overwrite each other's models.
export DBT_CI_SCHEMA=slim_gha_pr_${PR_NUMBER}
echo "PR #$PR_NUMBER builds in schema $DBT_CI_SCHEMA"

# Show what the PR changes: models, seeds, tests and so on. When this is
# empty, the build below selects nothing and passes.
echo "Nodes this PR changes:"
dbt ls --quiet --target ci --select state:modified --state "$STATE_DIR" --output name \
    | while read -r node; do echo "  $node"; done

# 4. Build what changed, and everything downstream. Unselected refs resolve to
#    prod. dbt 2.0.11 needs --favor-state for that: without it, a ref to a
#    model that doesn't exist in the PR schema resolves to the PR schema and
#    the build fails with TABLE_OR_VIEW_NOT_FOUND.
dbt build --target ci --select state:modified+ --defer --favor-state --state "$STATE_DIR"
