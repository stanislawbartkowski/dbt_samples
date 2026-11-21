#!/usr/bin/env bash
# The production job: build everything in the prod schema, then keep the
# manifest for Slim CI. Run on every merge to main (.github/workflows/dbt_prod.yml).
#
#   ci/prod_deploy.sh [STATE_DIR]
#
# The manifest is copied only after a successful build, so STATE_DIR always
# holds the last successful prod run. In GitHub Actions the workflow uploads
# target/manifest.json as an artifact instead.
set -euo pipefail

STATE_DIR=${1:-prod-state}

dbt build --target prod

mkdir -p "$STATE_DIR"
cp target/manifest.json "$STATE_DIR/manifest.json"
echo "Saved the prod manifest to $STATE_DIR/manifest.json"
