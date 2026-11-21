#!/usr/bin/env bash
# Stage four, across dbt versions: which target-aware configs does
# state:modified flag when nothing has changed?
#
# Builds a four-model project in a scratch directory. Each model sets
#   materialized: "{{ 'table' if target.name == 'prod' else 'view' }}"
# in a different place, or not at all:
#
#   m_project  dbt_project.yml
#   m_config   the model's config() block
#   m_yaml     properties YAML (models/props.yml)
#   m_plain    nowhere (always a view)
#
# For each dbt version, it writes a manifest with --target prod, then lists
# state:modified with --target ci. Nothing is built and no database is
# needed: dbt-core runs with the Postgres adapter from uvx, dbt v2 from .venv.
#
#   ./config_location_history.sh                  # every version below
#   VERSIONS="1.11 1.12" ./config_location_history.sh
#
# The first run downloads each dbt-core version (and Python 3.9 and 3.11).
set -uo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
# dbt v2 treats Postgres as an experimental adapter
export DBT_ALLOW_EXPERIMENTAL_ADAPTERS=true
VERSIONS=${VERSIONS:-"0.19 0.20 0.21 1.0 1.1 1.2 1.3 1.4 1.5 1.6 1.7 1.8 1.9 1.10 1.11 1.12 v2"}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1
mkdir -p models/in_project

cat >dbt_project.tmpl <<'EOF'
name: probe
version: '1.0.0'
config-version: 2
profile: probe
FLAGS
models:
  probe:
    in_project:
      +materialized: "{{ 'table' if target.name == 'prod' else 'view' }}"
EOF
echo "select 1 as id" >models/in_project/m_project.sql
printf '%s\n' "{{ config(materialized='table' if target.name == 'prod' else 'view') }}" "select 1 as id" >models/m_config.sql
echo "select 1 as id" >models/m_yaml.sql
echo "select 1 as id" >models/m_plain.sql
cat >models/props.yml <<'EOF'
version: 2
models:
  - name: m_yaml
    config:
      materialized: "{{ 'table' if target.name == 'prod' else 'view' }}"
EOF
# dbt-core only parses; it never connects.
cat >profiles.yml <<'EOF'
probe:
  target: ci
  outputs:
    prod: {type: postgres, host: localhost, port: 5432, user: dbt, password: dbt, dbname: dbt, schema: probe_prod, threads: 1}
    ci:   {type: postgres, host: localhost, port: 5432, user: dbt, password: dbt, dbname: dbt, schema: probe_ci, threads: 1}
EOF

# $1: "unset", "false" or "true" for state_modified_compare_more_unrendered_values
write_project() {
    if [ "$1" = unset ]; then
        sed '/^FLAGS$/d' dbt_project.tmpl >dbt_project.yml
    else
        sed "s/^FLAGS$/flags:\n  state_modified_compare_more_unrendered_values: $1/" dbt_project.tmpl >dbt_project.yml
    fi
}

dbt_cmd() {
    local v=$1 py="" extra="" pg
    if [ "$v" = v2 ]; then echo "$SRC/.venv/bin/dbt"; return; fi
    case $v in 0.*|1.[0-3]) py="--python 3.9" ;; 1.[4-6]) py="--python 3.11" ;; esac
    case $v in 0.*|1.0|1.1) extra="--with markupsafe<2.1 --with psycopg2-binary<2.9.6 --with pytz" ;; esac
    # From 1.8, adapters are versioned separately from dbt-core.
    case $v in 1.8) pg="~=1.8.0" ;; 1.9|1.1[0-9]) pg="~=1.9.0" ;; *) pg="~=$v.0" ;; esac
    echo "uvx -q $py --from dbt-core~=$v.0 --with dbt-postgres$pg $extra dbt"
}

printf '%-9s %-6s %s\n' "dbt" "flag" "state:modified, no change"
for v in $VERSIONS; do
    dbt=$(dbt_cmd "$v")
    # The flag exists from dbt-core 1.9; before 1.8, dbt rejects a flags: block.
    case $v in 0.*|1.[0-8]) flags="unset" ;; *) flags="unset false true" ;; esac
    for flag in $flags; do
        write_project "$flag"
        rm -rf "$WORK/target" "$WORK/prod-state"
        # dbt parse doesn't write manifest.json before 1.5; dbt ls always does.
        if ! out=$($dbt ls --profiles-dir . --target prod 2>&1); then
            echo "$v: dbt ls failed: $(grep -m1 -E '\[error\]|Error' <<<"$out" | cut -c1-150)"; continue
        fi
        mv "$WORK/target" "$WORK/prod-state"
        out=$($dbt ls --profiles-dir . --target ci --resource-type model --output name \
            --select state:modified --state prod-state 2>&1)
        version=$($dbt --version 2>&1 | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+')
        selected=$(grep -E '^m_' <<<"$out" | sort | tr '\n' ' ')
        printf '%-9s %-6s %s\n' "$version" "$flag" "${selected:-(nothing)}"
    done
done
