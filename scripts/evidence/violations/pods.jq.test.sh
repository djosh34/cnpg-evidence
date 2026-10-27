#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

facts='{"pods_sharing_host_uids": [], "host_network_pods_that_can_bind_low_ports": [], "details": {"instances": ["pg-1", "pg-2", "pg-3"]}}'

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
    jq -L "$here" -f "$here/pods.jq"
}

same "the clean cluster has none" '[]' "$(violations .)"

same "pods" \
  '["rule 6: pod pg-2 shares host uids", "rule 6: only 2 of 3 instance pods exist", "rule 8: pod otel/collector-x runs on the host network and can bind a port below 1024"]' \
  "$(violations '.pods_sharing_host_uids = ["pg-2"] | .details.instances = ["pg-1", "pg-2"]
                 | .host_network_pods_that_can_bind_low_ports = ["otel/collector-x"]')"

finish
