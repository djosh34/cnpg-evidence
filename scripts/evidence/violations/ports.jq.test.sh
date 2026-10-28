#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

values=$(cat <<'EOF2'
{"cluster": {"name": "pg", "namespace": "databases", "instances": 2}, "caSecret": "client-ca",
 "rwLoadBalancer": {"name": "pg-rw-lb"}, "readLoadBalancer": {"name": "pg-read-lb", "port": 5433},
 "network": {"operatorNamespace": "cnpg-system", "otelNamespace": "otel"},
 "replication": {"commonName": "pg-replication"}, "databases": []}
EOF2
)

# The clean facts are the expected Services.
facts=$(jq -c -L "$here" 'include "expected"; {ports: {services: expected_services, host_ports: {"pg-1": [], "pg-2": []}}}' <<<"$values")

# violations FILTER [VALUES_FILTER]: the sentences for the clean facts changed
# by a jq filter, against the values changed by another.
violations() {
  jq -c "$1" <<<"$facts" |
    jq --slurpfile values <(jq -c "${2:-.}" <<<"$values") '{facts: ., values: $values[0]}' |
    jq -L "$here" -f "$here/ports.jq"
}

same "the clean cluster has none" '[]' "$(violations .)"
same "CNPG's three Services, both LoadBalancers, health check port only on the read one" \
  '{"databases/pg-r": "none", "databases/pg-read-lb": "present", "databases/pg-ro": "none", "databases/pg-rw": "none", "databases/pg-rw-lb": "none"}' \
  "$(jq '.ports.services | map_values(.health_check_port)' <<<"$facts")"

same "an extra NodePort Service" \
  '["rule 9: Service databases/pg-nodeport reaches the instance pods: NodePort, ports 5432 -> 5432, node ports 30432, external IPs none"]' \
  "$(violations '.ports.services["databases/pg-nodeport"] = {type: "NodePort", selector: "cnpg.io/cluster=pg", traffic_policy: "Cluster",
                   ports: ["5432 -> 5432"], node_ports: [30432], health_check_port: "none", external_ips: []}')"
same "a Service without a selector in another namespace" \
  '["rule 9: Service otel/by-hand reaches the instance pods: ClusterIP, ports 6000 -> 5432, node ports none, external IPs none"]' \
  "$(violations '.ports.services["otel/by-hand"] = {type: "ClusterIP", selector: "none", traffic_policy: "none",
                   ports: ["6000 -> 5432"], node_ports: [], health_check_port: "none", external_ips: []}')"
same "a node port and an external IP on the rw LoadBalancer" \
  '["rule 9: Service databases/pg-rw-lb has node ports 32281, expected none",
    "rule 9: Service databases/pg-rw-lb has external IPs 192.0.2.10, expected none"]' \
  "$(violations '.ports.services["databases/pg-rw-lb"] |= (.node_ports = [32281] | .external_ips = ["192.0.2.10"])')"
same "the read LoadBalancer with another selector and traffic policy" \
  '["rule 9: Service databases/pg-read-lb has selector cnpg.io/cluster=pg,cnpg.io/instanceRole=primary, expected cnpg.io/cluster=pg,cnpg.io/podRole=instance",
    "rule 9: Service databases/pg-read-lb has traffic policy Cluster, expected Local",
    "rule 9: Service databases/pg-read-lb has health check port none, expected present"]' \
  "$(violations '.ports.services["databases/pg-read-lb"] |= (.selector = "cnpg.io/cluster=pg,cnpg.io/instanceRole=primary"
                   | .traffic_policy = "Cluster" | .health_check_port = "none")')"
same "the read LoadBalancer on another port" \
  '["rule 9: Service databases/pg-read-lb has ports 6432 -> 5432, expected 5433 -> 5432"]' \
  "$(violations '.ports.services["databases/pg-read-lb"].ports = ["6432 -> 5432"]')"
same "a missing Service" '["rule 9: Service databases/pg-ro does not reach the instance pods"]' \
  "$(violations 'del(.ports.services["databases/pg-ro"])')"
same "without readLoadBalancer in the values, a read LoadBalancer is extra" \
  '["rule 9: Service databases/pg-read-lb reaches the instance pods: LoadBalancer, ports 5433 -> 5432, node ports none, external IPs none"]' \
  "$(violations . 'del(.readLoadBalancer)')"
same "a host port" '["rule 9: pod pg-2 has host port 5432 -> 5432"]' "$(violations '.ports.host_ports["pg-2"] = ["5432 -> 5432"]')"

finish
