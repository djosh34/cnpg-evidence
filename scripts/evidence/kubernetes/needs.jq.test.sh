#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

input=$(cat <<'EOF'
{
  "subjects": ["alice", "system:serviceaccount:otel:collector"],
  "named_in": {"databases": ["alice"], "otel": ["group:system:serviceaccounts:otel"]},
  "namespaces": ["cnpg-system", "databases", "otel"],
  "component_namespaces": ["cnpg-system", "databases"],
  "secrets": {"databases": ["pg-replication"], "cnpg-system": ["cnpg-ca-secret"], "otel": ["otel-token"]},
  "instance_pods": ["pg-1", "pg-2"],
  "network_policies": ["pg-ingress"],
  "nodes": ["node-a"],
  "accounts": [{"namespace": "databases", "name": "pg"}, {"namespace": "cnpg-system", "name": "op"}],
  "namespace": "databases", "cluster": "pg",
  "operator_namespace": "cnpg-system", "operator_account": "op", "plugin_account": "plug",
  "ingress_routes": []
}
EOF
)
needs=$(jq -c -f "$here/needs.jq" <<<"$input")

asked() { jq -c --arg right "$1" --arg subject "$2" 'select(.right == $right and .subject == $subject) | [.in, .ask.namespace]' <<<"$needs" | jq -sc 'unique'; }

# questions RIGHT SUBJECT: verb, resource and subresource of every question for one right.
questions() {
  jq -c --arg right "$1" --arg subject "$2" 'select(.right == $right and .subject == $subject) | [.ask.verb, .ask.resource, .ask.subresource]' <<<"$needs" | jq -sc 'unique'
}

same "named in a RoleBinding there: asked in that namespace" \
  '[["databases", "databases"]]' "$(asked "read_secret pg-replication" alice)"
same "not named there: asked cluster-wide" \
  '[["databases", "-"]]' "$(asked "read_secret pg-replication" system:serviceaccount:otel:collector)"
same "named through its ServiceAccount group" \
  '[["cnpg-system", "-"], ["databases", "-"], ["otel", "otel"]]' "$(asked run_pods system:serviceaccount:otel:collector)"
same "cluster-wide rights are asked cluster-wide" \
  '[["", "-"]]' "$(asked proxy_to_nodes alice)"

same "exec into each instance pod by name" \
  '[["create","pods/pg-1","attach"],["create","pods/pg-1","exec"],["create","pods/pg-2","attach"],["create","pods/pg-2","exec"],
    ["get","pods/pg-1","attach"],["get","pods/pg-1","exec"],["get","pods/pg-2","attach"],["get","pods/pg-2","exec"],
    ["patch","pods/pg-1","ephemeralcontainers"],["patch","pods/pg-2","ephemeralcontainers"],
    ["create","pods","attach"],["create","pods","exec"],["get","pods","attach"],["get","pods","exec"],["patch","pods","ephemeralcontainers"]]' \
  "$(jq -c 'select(.right == "exec_into_pods" and .subject == "alice") | [.ask.verb, .ask.resource, .ask.subresource]' <<<"$needs" | jq -sc 'unique_by(.) | sort_by(.[1] == "pods", .)')"
same "port-forward to each instance pod by name, in the cluster's namespace only" \
  '[["databases","create","pods/pg-1","portforward"],["databases","create","pods/pg-2","portforward"],
    ["databases","get","pods/pg-1","portforward"],["databases","get","pods/pg-2","portforward"]]' \
  "$(jq -c 'select(.right == "port_forward" and .subject == "alice") | [.in, .ask.verb, .ask.resource, .ask.subresource]' <<<"$needs" | jq -sc 'unique')"
same "the instance pods and the operator's pods may be changed" \
  '[["cnpg-system","patch","pods"],["cnpg-system","update","pods"],["databases","patch","pods"],["databases","patch","pods/pg-1"],["databases","patch","pods/pg-2"],
    ["databases","update","pods"],["databases","update","pods/pg-1"],["databases","update","pods/pg-2"]]' \
  "$(jq -c 'select(.right == "change_pods" and .subject == "alice") | [.in, .ask.verb, .ask.resource]' <<<"$needs" | jq -sc 'unique')"
same "Secrets in the cluster's and the operator's namespace: read and written by name, listed, watched, created" \
  '[["cnpg-system","get","secrets/cnpg-ca-secret"],["cnpg-system","list","secrets"],["cnpg-system","watch","secrets"],
    ["databases","get","secrets/pg-replication"],["databases","list","secrets"],["databases","watch","secrets"],
    ["cnpg-system","create","secrets"],["cnpg-system","patch","secrets/cnpg-ca-secret"],["cnpg-system","update","secrets/cnpg-ca-secret"],
    ["databases","create","secrets"],["databases","patch","secrets/pg-replication"],["databases","update","secrets/pg-replication"]]' \
  "$(jq -c 'select((.right | test("^(read|write)_secret")) and .subject == "alice") | [.in, .ask.verb, .ask.resource, (.right | startswith("write"))]' <<<"$needs" |
     jq -sc 'unique | sort_by(.[3], .[0], .[1]) | map(.[:3])')"
same "the Cluster is created without a name and changed by name" \
  '[["create","clusters.postgresql.cnpg.io","-"],["patch","clusters.postgresql.cnpg.io/pg","-"],["update","clusters.postgresql.cnpg.io/pg","-"]]' \
  "$(questions "change clusters" alice)"
same "NetworkPolicies are also asked for delete, and by name" \
  '[["create","networkpolicies.networking.k8s.io","-"],["delete","networkpolicies.networking.k8s.io","-"],
    ["delete","networkpolicies.networking.k8s.io/pg-ingress","-"],["patch","networkpolicies.networking.k8s.io","-"],
    ["patch","networkpolicies.networking.k8s.io/pg-ingress","-"],["update","networkpolicies.networking.k8s.io","-"],
    ["update","networkpolicies.networking.k8s.io/pg-ingress","-"]]' \
  "$(questions "change networkpolicies" alice)"
same "Endpoints and EndpointSlices in the cluster's namespace are created or changed" \
  '[["databases","create","endpoints"],["databases","create","endpointslices.discovery.k8s.io"],
    ["databases","patch","endpoints"],["databases","patch","endpointslices.discovery.k8s.io"],
    ["databases","update","endpoints"],["databases","update","endpointslices.discovery.k8s.io"]]' \
  "$(jq -c 'select((.right | IN("change endpoints", "change endpointslices")) and .subject == "alice") | [.in, .ask.verb, .ask.resource]' <<<"$needs" | jq -sc 'unique')"
same "system:masters, cluster-admin and the component ServiceAccounts by name" \
  '[["bind","clusterroles.rbac.authorization.k8s.io/cluster-admin"],["escalate","clusterroles.rbac.authorization.k8s.io/cluster-admin"],
    ["impersonate","groups/system:masters"],["impersonate","serviceaccounts/op"],["impersonate","serviceaccounts/pg"]]' \
  "$(jq -c 'select(.subject == "alice" and (.ask.verb | IN("impersonate", "bind", "escalate")) and (.ask.resource | contains("/"))) | [.ask.verb, .ask.resource]' <<<"$needs" | jq -sc 'unique')"
same "node proxy for every node and by name" \
  '[["get","nodes","proxy"],["get","nodes/node-a","proxy"]]' "$(questions proxy_to_nodes alice)"

same "pods and every workload kind, ReplicationControllers too, created or changed" \
  '["cronjobs.batch","daemonsets.apps","deployments.apps","jobs.batch","pods","replicasets.apps","replicationcontrollers","statefulsets.apps"]' \
  "$(jq -c 'select(.right == "run_pods" and .subject == "alice" and .in == "otel") | .ask.resource' <<<"$needs" | jq -sc 'unique')"
same "Services and certificates are changed too" \
  '[["create","certificaterequests.cert-manager.io"],["create","certificates.cert-manager.io"],["create","services"],
    ["patch","certificates.cert-manager.io"],["patch","services"],["update","certificates.cert-manager.io"],["update","services"]]' \
  "$(jq -c 'select((.right | IN("change_services", "create_certificates")) and .subject == "alice" and .in == "otel") | [.ask.verb, .ask.resource]' <<<"$needs" | jq -sc 'unique')"
same "Ingresses always, IngressRoutes only where Traefik serves them" \
  '["ingresses.networking.k8s.io"]' \
  "$(jq -c 'select(.right == "change_ingresses") | .ask.resource' <<<"$needs" | jq -sc 'unique')"
same "with Traefik, IngressRoutes and IngressRouteTCPs too, created or changed" \
  '[["create","ingresses.networking.k8s.io"],["create","ingressroutes.traefik.io"],["create","ingressroutetcps.traefik.io"],
    ["patch","ingresses.networking.k8s.io"],["patch","ingressroutes.traefik.io"],["patch","ingressroutetcps.traefik.io"],
    ["update","ingresses.networking.k8s.io"],["update","ingressroutes.traefik.io"],["update","ingressroutetcps.traefik.io"]]' \
  "$(jq '.ingress_routes = ["ingressroutes.traefik.io", "ingressroutetcps.traefik.io"]' <<<"$input" | jq -c -f "$here/needs.jq" |
     jq -c 'select(.right == "change_ingresses" and .subject == "alice" and .in == "otel") | [.ask.verb, .ask.resource]' | jq -sc 'unique')"

same "the operator is asked to get, list and watch Secrets in every namespace, and to get each by name" \
  '[["cnpg-system","get","secrets"],["cnpg-system","get","secrets/cnpg-ca-secret"],["cnpg-system","list","secrets"],["cnpg-system","watch","secrets"],
    ["databases","get","secrets"],["databases","get","secrets/pg-replication"],["databases","list","secrets"],["databases","watch","secrets"],
    ["otel","get","secrets"],["otel","get","secrets/otel-token"],["otel","list","secrets"],["otel","watch","secrets"]]' \
  "$(jq -c 'select(.right == "operator_reads_secrets_in") | [.in, .ask.verb, .ask.resource]' <<<"$needs" | jq -sc 'unique')"
same "and the plugin the same" \
  '12' "$(jq -c 'select(.right == "plugin_reads_secrets_in") | [.in, .ask.verb, .ask.resource]' <<<"$needs" | jq -s 'unique | length')"

finish
