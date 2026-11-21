#!/usr/bin/env bash
# Drops a pull request's CI schema when the PR is closed or merged.
#
#   PR_NUMBER=123 ci/drop_pr_schema.sh
set -euo pipefail

: "${PR_NUMBER:?Set PR_NUMBER to the pull request number}"
export DBT_CI_SCHEMA=slim_gha_pr_${PR_NUMBER}
dbt run-operation drop_target_schema --target ci
