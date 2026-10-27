#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

clean='{"outside":[5432],"other nodes":[5432],"own node":["all"],"loadbalancer":[5432],"pg pods":[5432,8000],"cnpg-system operator":[8000],"otel":[9187],"other namespaces":[]}'
facts=$(jq -nc --argjson clean "$clean" '{network_policy: {"pg-1": $clean, "pg-2": $clean}}')

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
    jq -L "$here" -f "$here/network.jq"
}

same "the clean cluster has none" '[]' "$(violations .)"

same "a policy that opens only pg-2" '["rule 5: pod pg-2: source everyone can connect on all ports"]' \
  "$(violations '.network_policy["pg-2"].everyone = ["all"]')"

same "a source it cannot name" '["rule 5: pod pg-1: a NetworkPolicy source cannot be named: {\"ipBlock\":{\"cidr\":\"10.0.0.0/8\"}} on 5432"]' \
  "$(violations '.network_policy["pg-1"]["{\"ipBlock\":{\"cidr\":\"10.0.0.0/8\"}}"] = [5432]')"

same "the operator loses the status port everywhere" \
  '["rule 5: pod pg-1: source cnpg-system operator cannot connect on 8000", "rule 5: pod pg-2: source cnpg-system operator cannot connect on 8000"]' \
  "$(violations '.network_policy[]["cnpg-system operator"] = []')"

finish
