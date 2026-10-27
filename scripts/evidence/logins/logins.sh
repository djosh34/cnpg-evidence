#!/usr/bin/env bash
# The databases section: who logs in to which database, and how. pg_hba and
# pg_ident are read on every instance, roles and databases on the primary.
#
# Usage: logins.sh NAMESPACE PRIMARY_POD POD...
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
psql=$here/../psql/psql.sh

namespace=$1
primary=$2
shift 2

rules=$(
  for pod in "$@"; do
    bash "$psql" "$namespace" "$pod" <"$here/rules.sql" |
      jq -c --arg pod "$pod" '{key: $pod, value: .}'
  done
)

catalog=$(bash "$psql" "$namespace" "$primary" <"$here/catalog.sql")

jq -n \
  --slurpfile rules <(echo "$rules") \
  --slurpfile catalog <(echo "$catalog") \
  '{instances: ($rules | from_entries), catalog: $catalog[0]}' |
  jq -f "$here/logins.jq"
