#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

# The sample chart's Services as CNPG writes them, two instance pods, and
# Services that do not reach them: another namespace with the same selector,
# another cluster, and a slice that holds no instance address.
input=$(cat <<'EOF2'
{
  "namespace": "databases",
  "pods": [
    {"metadata": {"name": "pg-1", "labels": {"cnpg.io/cluster": "pg", "cnpg.io/podRole": "instance", "cnpg.io/instanceRole": "primary"}},
     "spec": {"containers": [{"name": "postgres", "ports": [{"containerPort": 5432}, {"containerPort": 9187}]}]},
     "status": {"podIPs": [{"ip": "10.42.0.5"}]}},
    {"metadata": {"name": "pg-2", "labels": {"cnpg.io/cluster": "pg", "cnpg.io/podRole": "instance", "cnpg.io/instanceRole": "replica"}},
     "spec": {"containers": [{"name": "postgres"}]},
     "status": {"podIPs": [{"ip": "10.42.1.7"}]}}
  ],
  "services": [
    {"metadata": {"namespace": "databases", "name": "pg-rw"},
     "spec": {"type": "ClusterIP", "selector": {"cnpg.io/instanceRole": "primary", "cnpg.io/cluster": "pg"},
              "ports": [{"name": "postgres", "port": 5432, "targetPort": 5432}]}},
    {"metadata": {"namespace": "databases", "name": "pg-r"},
     "spec": {"type": "ClusterIP", "selector": {"cnpg.io/cluster": "pg", "cnpg.io/podRole": "instance"},
              "ports": [{"port": 5432, "targetPort": 5432}]}},
    {"metadata": {"namespace": "databases", "name": "pg-rw-lb"},
     "spec": {"type": "LoadBalancer", "selector": {"cnpg.io/cluster": "pg", "cnpg.io/instanceRole": "primary"},
              "externalTrafficPolicy": "Cluster", "ports": [{"port": 5432, "targetPort": 5432}]}},
    {"metadata": {"namespace": "databases", "name": "pg-read-lb"},
     "spec": {"type": "LoadBalancer", "selector": {"cnpg.io/cluster": "pg", "cnpg.io/podRole": "instance"},
              "externalTrafficPolicy": "Local", "healthCheckNodePort": 31309, "ports": [{"port": 5433, "targetPort": 5432}]}},
    {"metadata": {"namespace": "otel", "name": "same-selector"},
     "spec": {"type": "ClusterIP", "selector": {"cnpg.io/cluster": "pg"}, "ports": [{"port": 5432}]}},
    {"metadata": {"namespace": "databases", "name": "other-rw"},
     "spec": {"type": "ClusterIP", "selector": {"cnpg.io/cluster": "other"}, "ports": [{"port": 5432}]}},
    {"metadata": {"namespace": "default", "name": "kubernetes"},
     "spec": {"type": "ClusterIP", "ports": [{"port": 443, "targetPort": 6443}]}}
  ],
  "endpoint_slices": [
    {"metadata": {"namespace": "databases", "labels": {"kubernetes.io/service-name": "pg-rw"}},
     "endpoints": [{"addresses": ["10.42.0.5"]}]},
    {"metadata": {"namespace": "default", "labels": {"kubernetes.io/service-name": "kubernetes"}},
     "endpoints": [{"addresses": ["192.0.2.1"]}]}
  ]
}
EOF2
)

ports() { jq -c -f "$here/ports.jq"; }

expected=$(cat <<'EOF2'
{
  "databases/pg-rw": {"type": "ClusterIP", "selector": "cnpg.io/cluster=pg,cnpg.io/instanceRole=primary", "traffic_policy": "none",
                      "ports": ["5432 -> 5432"], "node_ports": [], "health_check_port": "none", "external_ips": []},
  "databases/pg-r": {"type": "ClusterIP", "selector": "cnpg.io/cluster=pg,cnpg.io/podRole=instance", "traffic_policy": "none",
                     "ports": ["5432 -> 5432"], "node_ports": [], "health_check_port": "none", "external_ips": []},
  "databases/pg-rw-lb": {"type": "LoadBalancer", "selector": "cnpg.io/cluster=pg,cnpg.io/instanceRole=primary", "traffic_policy": "Cluster",
                         "ports": ["5432 -> 5432"], "node_ports": [], "health_check_port": "none", "external_ips": []},
  "databases/pg-read-lb": {"type": "LoadBalancer", "selector": "cnpg.io/cluster=pg,cnpg.io/podRole=instance", "traffic_policy": "Local",
                           "ports": ["5433 -> 5432"], "node_ports": [], "health_check_port": "present", "external_ips": []}
}
EOF2
)
same "the Services that select an instance pod in its namespace, and no other" "$expected" "$(ports <<<"$input" | jq .services)"
same "no host port" '{"pg-1": [], "pg-2": []}' "$(ports <<<"$input" | jq .host_ports)"

# by_hand SLICE_PORTS: the entry of a Service without a selector in another
# namespace, ports postgres 6000 (targetPort 9999, which it does not use) and
# metrics 7000, whose EndpointSlice holds pg-2's address with these ports.
by_hand() {
  jq --argjson slice_ports "$1" \
    '.services += [{metadata: {namespace: "otel", name: "by-hand"},
                    spec: {type: "ClusterIP", ports: [{name: "postgres", port: 6000, targetPort: 9999}, {name: "metrics", port: 7000}]}}]
     | .endpoint_slices += [{metadata: {namespace: "otel", labels: {"kubernetes.io/service-name": "by-hand"}},
                             ports: $slice_ports, endpoints: [{addresses: ["10.0.0.9"]}, {addresses: ["10.42.1.7"]}]}]' <<<"$input" |
    ports | jq -c '.services["otel/by-hand"]'
}
same "a Service without a selector in another namespace, through an EndpointSlice address, to the slice's ports" \
  '{"type": "ClusterIP", "selector": "none", "traffic_policy": "none", "ports": ["6000 -> 5432", "7000 -> none"], "node_ports": [],
    "health_check_port": "none", "external_ips": []}' \
  "$(by_hand '[{"name": "postgres", "port": 5432}]')"
same "a slice port without a number leads to every port" '["6000 -> all", "7000 -> 9187"]' \
  "$(by_hand '[{"name": "postgres"}, {"name": "metrics", "port": 9187}]' | jq -c .ports)"

same "an EndpointSlice of no Service does not count" '["databases/pg-r", "databases/pg-read-lb", "databases/pg-rw", "databases/pg-rw-lb"]' \
  "$(jq '.endpoint_slices += [{metadata: {namespace: "otel", labels: {}}, endpoints: [{addresses: ["10.42.1.7"]}]}]' <<<"$input" |
     ports | jq '.services | keys')"

same "node ports, external IPs and other protocols" \
  '{"type": "NodePort", "selector": "cnpg.io/podRole=instance", "traffic_policy": "Cluster", "ports": ["5432 -> postgres", "UDP/53 -> 53"],
    "node_ports": [32281], "health_check_port": "none", "external_ips": ["192.0.2.10"]}' \
  "$(jq '.services += [{metadata: {namespace: "databases", name: "extra"},
                        spec: {type: "NodePort", selector: {"cnpg.io/podRole": "instance"}, externalTrafficPolicy: "Cluster",
                               externalIPs: ["192.0.2.10"],
                               ports: [{port: 5432, targetPort: "postgres", nodePort: 32281}, {protocol: "UDP", port: 53}]}}]' <<<"$input" |
     ports | jq '.services["databases/extra"]')"

same "a Service without ports limits no port" '["all"]' \
  "$(jq '.services += [{metadata: {namespace: "databases", name: "headless"},
                        spec: {type: "ClusterIP", clusterIP: "None", selector: {"cnpg.io/cluster": "pg"}}}]' <<<"$input" |
     ports | jq -c '.services["databases/headless"].ports')"

same "host ports of containers and init containers" '{"pg-1": ["5432 -> 5432", "UDP/9000 -> 9000"], "pg-2": []}' \
  "$(jq '.pods[0].spec.containers[0].ports[0].hostPort = 5432
         | .pods[0].spec.initContainers = [{name: "sidecar", ports: [{containerPort: 9000, hostPort: 9000, protocol: "UDP"}]}]' <<<"$input" |
     ports | jq .host_ports)"

if jq '.pods = []' <<<"$input" | ports >/dev/null 2>&1; then
  fail "no instance pod fails"
else
  pass "no instance pod fails"
fi

finish
