#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

# The databases and details of a clean cluster.
facts=$(cat <<'JSON'
{
"databases": {
  "billing": {"owner":"billing","logins":{"billing":{"common_names":["billing-app.test","billing-report.test"]},"cnpg_metrics_exporter":{"os_users":["postgres"]},"postgres":{"os_users":["postgres"]}}},
  "orders": {"owner":"orders","logins":{"cnpg_metrics_exporter":{"os_users":["postgres"]},"orders":{"common_names":["orders-app.test"]},"postgres":{"os_users":["postgres"]}}},
  "postgres": {"owner":"postgres","logins":{"cnpg_metrics_exporter":{"os_users":["postgres"]},"postgres":{"os_users":["postgres"]},"streaming_replica":{"common_names":["pg-replication","streaming_replica"]}}},
  "template0": {"owner":"postgres","allows_connections":false},
  "template1": {"owner":"postgres","logins":{"cnpg_metrics_exporter":{"os_users":["postgres"]},"postgres":{"os_users":["postgres"]}}},
  "replication": {"logins":{"streaming_replica":{"common_names":["pg-replication","streaming_replica"]}}}
},
"details": {"pg_hba":[],"pg_ident":[],"pg_hba_not_understood":[],"pg_ident_not_understood":[]}
}
JSON
)

values=$(cat <<'EOF'
{"cluster": {"name": "pg", "namespace": "databases", "instances": 3}, "caSecret": "client-ca",
 "rwLoadBalancer": {"name": "pg-rw-lb"}, "network": {"operatorNamespace": "cnpg-system", "otelNamespace": "otel"},
 "replication": {"commonName": "pg-replication"},
 "databases": [{"name": "orders", "role": "orders", "clientCNs": ["orders-app.test"]},
               {"name": "billing", "role": "billing", "clientCNs": ["billing-app.test", "billing-report.test"]}]}
EOF
)

# violations FILTER: the sentences for the clean facts changed by a jq filter.
violations() {
  jq -c "$1" <<<"$facts" |
    jq --slurpfile values <(echo "$values") \
      '{facts: ., values: $values[0]}' |
    jq -L "$here" -f "$here/databases.jq"
}

same "the clean cluster has none" '[]' "$(violations .)"

same "a password path before the reject" '["rule 2: database orders: role orders can log in with a password"]' \
  "$(violations '.databases.orders.logins.orders.password = true')"

same "a common name of another database" '["rule 1: database billing: role orders logs in with common name orders-app.test"]' \
  "$(violations '.databases.billing.logins.orders = {common_names: ["orders-app.test"]}')"

same "a common name that maps nowhere" '["rule 1: common name billing-report.test maps to no role"]' \
  "$(violations '.databases.billing.logins.billing.common_names = ["billing-app.test"]')"

same "the app database" '["rule 4: database app exists"]' \
  "$(violations '.databases.app = {owner: "app", logins: {}}')"

same "a missing database and another owner" \
  '["rule 1: database orders is owned by postgres, not orders", "rule 1: database billing does not exist"]' \
  "$(violations 'del(.databases.billing) | .databases.orders.owner = "postgres"')"

same "lines it cannot read, instances that differ" \
  '["rule 1: pg_hba differs between instances", "rule 1: pg_hba line cannot be read: host all all all ldap"]' \
  "$(violations '.details.pg_hba = {"pg-1": [], "pg-2": ["x"]} | .details.pg_hba_not_understood = ["host all all all ldap"]')"

finish
