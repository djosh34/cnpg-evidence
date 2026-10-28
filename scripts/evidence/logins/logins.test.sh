#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

# rules.sql answers with one reject line per pod and the same pg_ident lines,
# one of them with an error.
kubectl() {
  local pod=$5
  grep -q "'pg_hba'" || return 1
  if [[ $pod == *-fails ]]; then
    return 1
  fi
  cat <<EOF
{"pg_hba": [{"number": 1, "line": "host all all all reject $pod", "type": "host", "databases": ["all"], "users": ["all"],
             "address": "all", "method": "reject", "options": [], "error": null}],
 "pg_ident": [{"number": 1, "line": "clients orders-app.test orders", "map": "clients", "system_user": "orders-app.test",
               "role": "orders", "error": null},
              {"number": null, "line": "clients x error: bad", "map": "clients", "system_user": "x", "role": null,
               "error": "bad"}]}
EOF
}
export -f kubectl

expected=$(cat <<'EOF'
{
  "pg_hba": {
    "pg-1": [{"number": 1, "line": "host all all all reject pg-1"}],
    "pg-2": [{"number": 1, "line": "host all all all reject pg-2"}]
  },
  "pg_ident": [{"number": 1, "line": "clients orders-app.test orders"}, {"number": null, "line": "clients x error: bad"}],
  "ident": [{"map": "clients", "system_user": "orders-app.test", "role": "orders"}]
}
EOF
)
same "reads the rules of every pod; one list where they agree, mappings without errors" \
  "$expected" "$(bash "$here/logins.sh" databases pg-1 pg-2)"

# pg-2 has the same pg_ident lines in another order.
same "pg_ident lines in another order are the same lines" '[{"number":1,"line":"clients a.test orders"},{"number":2,"line":"clients b.test orders"}]' \
  "$(jq -n '{"pg-1": {pg_hba: [], pg_ident: [{number: 1, line: "clients a.test orders", map: "clients", system_user: "a.test", role: "orders", error: null},
                                           {number: 2, line: "clients b.test orders", map: "clients", system_user: "b.test", role: "orders", error: null}]},
             "pg-2": {pg_hba: [], pg_ident: [{number: 1, line: "clients b.test orders", map: "clients", system_user: "b.test", role: "orders", error: null},
                                           {number: 2, line: "clients a.test orders", map: "clients", system_user: "a.test", role: "orders", error: null}]}}' |
     jq -c -f "$here/logins.jq" | jq -c .pg_ident)"

if bash "$here/logins.sh" databases pg-1 pg-3-fails >/dev/null 2>&1; then
  fail "a failed read on one pod fails"
else
  pass "a failed read on one pod fails"
fi

finish
