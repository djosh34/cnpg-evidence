#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

values=$(cat <<'EOF'
{"cluster": {"name": "pg", "namespace": "databases", "instances": 3}, "caSecret": "client-ca",
 "rwLoadBalancer": {"name": "pg-rw-lb"}, "network": {"operatorNamespace": "cnpg-system"},
 "replication": {"commonName": "pg-replication"},
 "databases": [{"name": "orders", "role": "orders", "clientCNs": ["orders-app.test"]}]}
EOF
)

# The login rules of a clean cluster, numbered as the views number them.
details=$(jq -c -L "$here" 'include "expected";
  def numbered: to_entries | map({number: (.key + 1), line: .value});
  {pg_hba: (expected_pg_hba | numbered), pg_ident: (expected_pg_ident | numbered)}' <<<"$values")

# violations FILTER: the sentences for the clean details changed by a jq filter.
violations() {
  jq -c "$1" <<<"$details" |
    jq --slurpfile values <(echo "$values") '{facts: {details: .}, values: $values[0]}' |
    jq -L "$here" -f "$here/logins.jq"
}

same "the clean cluster has none" '[]' "$(violations .)"

same "a password line before the reject" \
  '["rule 1: pg_hba line 7 is \"host all all all scram-sha-256\", not \"host all all all reject\"",
    "rule 1: pg_hba line 8 is \"host all all all reject\", not \"host all all all scram-sha-256\""]' \
  "$(violations '.pg_hba |= (.[:6] + [.[7], .[6]])')"

same "an extra and a missing pg_hba line" \
  '["rule 1: pg_hba has an extra line 9: host all all all trust"]' \
  "$(violations '.pg_hba += [{number: 9, line: "host all all all trust"}]')"
same "a missing pg_hba line" \
  '["rule 1: pg_hba lacks line 8: host all all all scram-sha-256"]' \
  "$(violations '.pg_hba |= .[:7]')"

same "pg_ident in another order is the same" '[]' "$(violations '.pg_ident |= reverse')"
same "an extra and a missing pg_ident line" \
  '["rule 1: pg_ident has an extra line: clients other.test orders", "rule 1: pg_ident lacks the line: clients orders-app.test orders"]' \
  "$(violations '.pg_ident |= map(if .line == "clients orders-app.test orders" then .line = "clients other.test orders" else . end)')"

same "lines that differ between instances" \
  '["rule 1: pg_hba differs between instances", "rule 1: pg_ident differs between instances"]' \
  "$(violations '.pg_hba = {"pg-1": [], "pg-2": .pg_hba} | .pg_ident = {"pg-1": [], "pg-2": .pg_ident}')"

finish
