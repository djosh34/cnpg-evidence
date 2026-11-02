#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

facts='{"client_ca": {"secret":"client-ca","certificates":[{"name":"CN=example-ca","sha256_fingerprint":"2E:18"}]}}'

values=$(cat <<'EOF'
{"cluster": {"name": "pg", "namespace": "databases", "instances": 3}, "caSecret": "client-ca",
 "rwLoadBalancer": {"name": "pg-rw-lb"}, "network": {"operatorNamespace": "cnpg-system"},
 "replication": {"commonName": "pg-replication"},
 "databases": [{"name": "orders", "role": "orders", "clientCNs": ["orders-app.test"]},
               {"name": "billing", "role": "billing", "clientCNs": ["billing-app.test", "billing-report.test"]}]}
EOF
)

# found FILTER: the violations for the clean facts changed by a jq filter.
found() {
  jq -c "$1" <<<"$facts" |
    jq --slurpfile values <(echo "$values") \
      '{facts: ., values: $values[0], expected_ca: [{name: "CN=example-ca", sha256_fingerprint: "2E:18"}]}' |
    jq -L "$here" -f "$here/client-ca.jq"
}
# violations and paths: the sentences and the paths of what found gives.
violations() { found "$@" | jq -c 'map(.sentence)'; }
paths() { found "$@" | jq -c 'map(.path)'; }

same "the clean cluster has none" '[]' "$(violations .)"

same "another client CA" \
  '["rule 1: client CA secret client-ca also trusts CN=other (sha256 AA)"]' \
  "$(violations '.client_ca.certificates += [{name: "CN=other", sha256_fingerprint: "AA"}]')"

same "another secret without the client CA" \
  '["rule 1: client certificates are checked against secret pg-ca, not client-ca", "rule 1: client CA secret pg-ca lacks CN=example-ca (sha256 2E:18)"]' \
  "$(violations '.client_ca = {secret: "pg-ca", certificates: []}')"

same "about the secret and the certificates" '[["client_ca","secret"],["client_ca","certificates"]]' \
  "$(paths '.client_ca = {secret: "pg-ca", certificates: []}')"

finish
