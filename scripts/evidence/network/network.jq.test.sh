#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

network() { jq -c -f "$here/network.jq"; }
# pg_1: the sources of pg-1 only.
pg_1() { network | jq -c '.["pg-1"]'; }

# The samples chart's policy on a two-node cluster.
input=$(cat <<'EOF'
{
  "namespace": "databases", "cluster": "pg", "load_balancer": "pg-rw-lb",
  "operator_namespace": "cnpg-system", "otel_namespace": "otel",
  "pods": {
    "pg-1": {"cnpg.io/cluster": "pg", "cnpg.io/podRole": "instance", "cnpg.io/instanceName": "pg-1", "cnpg.io/instanceRole": "primary"},
    "pg-2": {"cnpg.io/cluster": "pg", "cnpg.io/podRole": "instance", "cnpg.io/instanceName": "pg-2", "cnpg.io/instanceRole": "replica"}
  },
  "node_pod_cidrs": ["10.42.0.0/24", "10.42.1.0/24"],
  "policies": [{"spec": {
    "podSelector": {"matchLabels": {"cnpg.io/cluster": "pg"}},
    "policyTypes": ["Ingress"],
    "ingress": [
      {"from": [{"podSelector": {"matchLabels": {"cnpg.io/cluster": "pg"}}}],
       "ports": [{"protocol": "TCP", "port": 5432}, {"protocol": "TCP", "port": 8000}]},
      {"from": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "cnpg-system"}},
                 "podSelector": {"matchLabels": {"app.kubernetes.io/name": "cloudnative-pg"}}}],
       "ports": [{"protocol": "TCP", "port": 8000}]},
      {"from": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "otel"}}}],
       "ports": [{"protocol": "TCP", "port": 9187}]},
      {"from": [
         {"ipBlock": {"cidr": "0.0.0.0/0", "except": ["10.42.1.0/24", "10.42.0.0/24"]}},
         {"ipBlock": {"cidr": "10.42.0.0/32"}},
         {"ipBlock": {"cidr": "10.42.1.0/32"}},
         {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}},
          "podSelector": {"matchLabels": {"svccontroller.k3s.cattle.io/svcname": "pg-rw-lb",
                                          "svccontroller.k3s.cattle.io/svcnamespace": "databases"}}}],
       "ports": [{"protocol": "TCP", "port": 5432}]}
    ]}}]
}
EOF
)

expected=$(cat <<'EOF'
{"outside": [5432], "other nodes": [5432], "own node": ["all"], "loadbalancer": [5432],
 "pg pods": [5432, 8000], "cnpg-system operator": [8000], "otel": [9187], "other namespaces": []}
EOF
)
same "the samples policy names every source, for every pod" \
  "$(jq -n --argjson e "$expected" '{"pg-1": $e, "pg-2": $e}')" "$(network <<<"$input")"

replica_open='{"spec": {"podSelector": {"matchLabels": {"cnpg.io/instanceName": "pg-2"}}, "ingress": [{}]}}'
same "a policy that selects only pg-2 opens only pg-2" \
  '{"pg-1": null, "pg-2": ["all"]}' \
  "$(jq --argjson p "$replica_open" '.policies += [$p]' <<<"$input" | network | jq -c 'map_values(.everyone)')"

allow_all='{"spec": {"podSelector": {}, "ingress": [{}]}}'
same "a second policy that allows all adds everyone on all ports" \
  '["all"]' "$(jq --argjson p "$allow_all" '.policies += [$p]' <<<"$input" | pg_1 | jq -c '.everyone')"

other_pods='{"spec": {"podSelector": {"matchLabels": {"app": "web"}}, "ingress": [{}]}}'
same "a policy for other pods does not count" \
  "$expected" "$(jq --argjson p "$other_pods" '.policies += [$p]' <<<"$input" | pg_1)"

egress_only='{"spec": {"podSelector": {}, "policyTypes": ["Egress"]}}'
same "no ingress policy at all lets everyone in" \
  '["all"]' "$(jq --argjson p "$egress_only" '.policies = [$p]' <<<"$input" | pg_1 | jq -c '.everyone')"

old_except=$(jq -c '.policies[0].spec.ingress[3].from[0].ipBlock.except = ["10.42.0.0/16"]' <<<"$input")
same "an except list that is not the node ranges is shown raw" \
  '{"{\"ipBlock\":{\"cidr\":\"0.0.0.0/0\",\"except\":[\"10.42.0.0/16\"]}}": [5432]}' \
  "$(pg_1 <<<"$old_except" | jq -c 'with_entries(select(.key | startswith("{")))')"

ports='{"spec": {"podSelector": {"matchExpressions": [{"key": "cnpg.io/cluster", "operator": "In", "values": ["pg"]}]},
        "ingress": [{"from": [{"namespaceSelector": {}}],
                     "ports": [{"port": 9187}, {"port": 5432, "endPort": 5440}, {"protocol": "UDP", "port": 53}, {"port": "metrics"}]}]}}'
same "port ranges, protocols and named ports; every namespace" \
  '[9187, "5432-5440", "UDP/53", "metrics"]' \
  "$(jq --argjson p "$ports" '.policies += [$p]' <<<"$input" | pg_1 | jq -c '.["other namespaces"]')"

finish
