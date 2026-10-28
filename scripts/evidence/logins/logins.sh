#!/usr/bin/env bash
# The login rules: the pg_hba and pg_ident lines of every instance.
#
# Usage: logins.sh NAMESPACE POD...
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
psql=$here/../psql/psql.sh

namespace=$1
shift

rules=$(
  for pod in "$@"; do
    bash "$psql" "$namespace" "$pod" <"$here/rules.sql" |
      jq -c --arg pod "$pod" '{key: $pod, value: .}'
  done
)

jq -s 'from_entries' <<<"$rules" | jq -f "$here/logins.jq"
