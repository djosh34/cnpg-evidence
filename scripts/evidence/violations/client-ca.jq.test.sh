#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

facts='{"client_ca": {"secret":"client-ca","certificates":[{"name":"CN=example-ca","sha256_fingerprint":"2E:18"}]}}'

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
      '{facts: ., values: $values[0], expected_ca: [{name: "CN=example-ca", sha256_fingerprint: "2E:18"}]}' |
    jq -L "$here" -f "$here/client-ca.jq"
}

same "the clean cluster has none" '[]' "$(violations .)"

same "another client CA" \
  '["rule 1: client CA secret client-ca also trusts CN=other (sha256 AA)"]' \
  "$(violations '.client_ca.certificates += [{name: "CN=other", sha256_fingerprint: "AA"}]')"

same "another secret without the client CA" \
  '["rule 1: client certificates are checked against secret pg-ca, not client-ca", "rule 1: client CA secret pg-ca lacks CN=example-ca (sha256 2E:18)"]' \
  "$(violations '.client_ca = {secret: "pg-ca", certificates: []}')"

finish
