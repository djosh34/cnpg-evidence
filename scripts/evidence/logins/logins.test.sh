#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

# rules.sql answers with one reject line per pod, catalog.sql only on pg-1.
kubectl() {
  local pod=$5 sql
  sql=$(cat)
  if [[ $pod == *-fails ]]; then
    return 1
  elif [[ $sql == *"'pg_hba'"* ]]; then
    cat <<EOF
{"pg_hba": [{"line": "host all all all reject $pod", "type": "host", "databases": ["all"], "users": ["all"],
             "address": "all", "method": "reject", "options": [], "error": null}],
 "pg_ident": []}
EOF
  elif [[ $sql == *"'roles'"* && $pod == pg-1 ]]; then
    cat <<'EOF'
{"roles": [{"name": "postgres", "member_of": ["postgres"]}],
 "databases": [{"name": "postgres", "owner": "postgres", "allows_connections": true, "connect": ["PUBLIC", "postgres"]}]}
EOF
  else
    return 1
  fi
}
export -f kubectl

expected=$(cat <<'EOF'
{
  "databases": {
    "postgres": {"owner": "postgres", "connect": ["PUBLIC", "postgres"], "logins": {}},
    "replication": {"logins": {}}
  },
  "details": {
    "pg_hba": {
      "pg-1": ["host all all all reject pg-1"],
      "pg-2": ["host all all all reject pg-2"]
    },
    "pg_ident": [],
    "pg_hba_not_understood": [],
    "pg_ident_not_understood": []
  }
}
EOF
)
same "reads the rules of every pod and the catalog of the primary" \
  "$expected" "$(bash "$here/logins.sh" databases pg-1 pg-1 pg-2)"

if bash "$here/logins.sh" databases pg-1 pg-1 pg-3-fails >/dev/null 2>&1; then
  fail "a failed read on one pod fails"
else
  pass "a failed read on one pod fails"
fi

finish
