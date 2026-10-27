#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

# The postgres facts of a clean cluster.
facts=$(cat <<'JSON'
{"postgres": {"superusers":["postgres"],"can_create_roles":["postgres"],"can_create_databases":["postgres"],"can_replicate":["postgres","streaming_replica"],"can_bypass_row_security":["postgres"],"can_run_server_programs":["postgres"],"can_read_server_files":["postgres","streaming_replica"],"can_write_server_files":["postgres"],"can_read_all_data":["postgres"],"can_write_all_data":["postgres"],"have_password":[],"can_log_in":["billing","cnpg_metrics_exporter","orders","postgres","streaming_replica"],"roles":["billing","cnpg_metrics_exporter","orders","postgres","streaming_replica"]}}
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
    jq -L "$here" -f "$here/postgres.jq"
}

same "the clean cluster has none" '[]' "$(violations .)"

same "a password" '["rule 2: role billing has a password"]' \
  "$(violations '.postgres.have_password = ["billing"]')"

same "CREATEDB on an application role" '["rule 3: role orders can create databases"]' \
  "$(violations '.postgres.can_create_databases += ["orders"]')"

same "file writes through pg_monitor" '["rule 3: role cnpg_metrics_exporter can write server files"]' \
  "$(violations '.postgres.can_write_server_files += ["cnpg_metrics_exporter"]')"

same "the app role, even NOLOGIN" '["rule 4: role app exists"]' \
  "$(violations '.postgres.roles += ["app"]')"

same "another role, even NOLOGIN" '["rule 1: role hidden exists and is not in the values"]' \
  "$(violations '.postgres.roles += ["hidden"]')"

same "a role from the values that does not exist" '["rule 1: role billing does not exist"]' \
  "$(violations '.postgres.roles -= ["billing"] | .postgres.can_log_in -= ["billing"]')"

same "a role from the values that cannot log in" '["rule 1: role billing cannot log in"]' \
  "$(violations '.postgres.can_log_in -= ["billing"]')"

finish
