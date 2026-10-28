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
  "secrets": {"databases": ["pg-replication"], "cnpg-system": ["cnpg-ca-secret"], "otel": ["otel-token"]},
  "instance_pods": ["pg-1", "pg-2"],
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
  '[["databases", "databases"]]' "$(asked superuser_in_cluster_namespace alice)"
same "not named there: asked cluster-wide" \
  '[["databases", "-"]]' "$(asked superuser_in_cluster_namespace system:serviceaccount:otel:collector)"
same "named through its ServiceAccount group" \
  '[["cnpg-system", "-"], ["databases", "-"], ["otel", "otel"]]' "$(asked run_pods system:serviceaccount:otel:collector)"
same "cluster-wide rights are asked cluster-wide" \
  '[["", "-"]]' "$(jq -c 'select(.right == "become_cluster_admin" and .subject == "alice" and .ask.verb == "get") | [.in, .ask.namespace]' <<<"$needs" | jq -sc unique)"

same "superuser in the cluster's namespace: the instance pods by name, workloads, its Secrets, its token and its CNPG objects" \
  '[["create","clusters.postgresql.cnpg.io","-"],["create","cronjobs.batch","-"],["create","daemonsets.apps","-"],
    ["create","databaseroles.postgresql.cnpg.io","-"],["create","databases.postgresql.cnpg.io","-"],["create","deployments.apps","-"],
    ["create","jobs.batch","-"],["create","objectstores.barmancloud.cnpg.io","-"],
    ["create","pods","-"],["create","pods/pg-1","attach"],["create","pods/pg-1","exec"],["create","pods/pg-2","attach"],["create","pods/pg-2","exec"],
    ["create","replicasets.apps","-"],["create","replicationcontrollers","-"],["create","secrets","-"],
    ["create","serviceaccounts/pg","token"],["create","statefulsets.apps","-"],
    ["get","pods/pg-1","attach"],["get","pods/pg-1","exec"],["get","pods/pg-2","attach"],["get","pods/pg-2","exec"],
    ["get","secrets/pg-replication","-"],["list","secrets","-"],
    ["patch","clusters.postgresql.cnpg.io/pg","-"],["patch","cronjobs.batch","-"],["patch","daemonsets.apps","-"],
    ["patch","databaseroles.postgresql.cnpg.io","-"],["patch","databases.postgresql.cnpg.io","-"],["patch","deployments.apps","-"],
    ["patch","jobs.batch","-"],["patch","objectstores.barmancloud.cnpg.io","-"],
    ["patch","pods","-"],["patch","pods/pg-1","-"],["patch","pods/pg-1","ephemeralcontainers"],["patch","pods/pg-2","-"],["patch","pods/pg-2","ephemeralcontainers"],
    ["patch","replicasets.apps","-"],["patch","replicationcontrollers","-"],["patch","secrets/pg-replication","-"],["patch","statefulsets.apps","-"],
    ["update","clusters.postgresql.cnpg.io/pg","-"],["update","cronjobs.batch","-"],["update","daemonsets.apps","-"],
    ["update","databaseroles.postgresql.cnpg.io","-"],["update","databases.postgresql.cnpg.io","-"],["update","deployments.apps","-"],
    ["update","jobs.batch","-"],["update","objectstores.barmancloud.cnpg.io","-"],
    ["update","pods","-"],["update","pods/pg-1","-"],["update","pods/pg-2","-"],
    ["update","replicasets.apps","-"],["update","replicationcontrollers","-"],["update","secrets/pg-replication","-"],["update","statefulsets.apps","-"],
    ["watch","secrets","-"]]' \
  "$(questions superuser_in_cluster_namespace alice)"
same "superuser rights are asked in the cluster's namespace only" \
  '["databases"]' "$(jq -c 'select(.right == "superuser_in_cluster_namespace") | .in' <<<"$needs" | jq -sc unique)"
same "system:masters, cluster-admin and the component ServiceAccounts by name" \
  '[["bind","clusterroles.rbac.authorization.k8s.io/cluster-admin"],["escalate","clusterroles.rbac.authorization.k8s.io/cluster-admin"],
    ["impersonate","groups/system:masters"],["impersonate","serviceaccounts/op"],["impersonate","serviceaccounts/pg"]]' \
  "$(jq -c 'select(.subject == "alice" and (.ask.verb | IN("impersonate", "bind", "escalate")) and (.ask.resource | contains("/"))) | [.ask.verb, .ask.resource]' <<<"$needs" | jq -sc 'unique')"
same "node proxy for every node and by name" \
  '[["get","nodes","proxy"],["get","nodes/node-a","proxy"]]' \
  "$(jq -c 'select(.right == "become_cluster_admin" and .subject == "alice" and .ask.verb == "get") | [.ask.verb, .ask.resource, .ask.subresource]' <<<"$needs" | jq -sc unique)"

same "pods and every workload kind, ReplicationControllers too, created or changed in every namespace" \
  '["cronjobs.batch","daemonsets.apps","deployments.apps","jobs.batch","pods","replicasets.apps","replicationcontrollers","statefulsets.apps"]' \
  "$(jq -c 'select(.right == "run_pods" and .subject == "alice" and .in == "otel") | .ask.resource' <<<"$needs" | jq -sc 'unique')"
same "Certificates and CertificateRequests created, Certificates changed" \
  '[["create","certificaterequests.cert-manager.io","-"],["create","certificates.cert-manager.io","-"],
    ["patch","certificates.cert-manager.io","-"],["update","certificates.cert-manager.io","-"]]' \
  "$(questions create_certificates alice)"
same "Ingresses always, IngressRoutes only where Traefik serves them" \
  '["ingresses.networking.k8s.io"]' \
  "$(jq -c 'select(.right == "write_routes") | .ask.resource' <<<"$needs" | jq -sc 'unique')"
same "with Traefik, IngressRoutes and IngressRouteTCPs too, created or changed" \
  '[["create","ingresses.networking.k8s.io"],["create","ingressroutes.traefik.io"],["create","ingressroutetcps.traefik.io"],
    ["patch","ingresses.networking.k8s.io"],["patch","ingressroutes.traefik.io"],["patch","ingressroutetcps.traefik.io"],
    ["update","ingresses.networking.k8s.io"],["update","ingressroutes.traefik.io"],["update","ingressroutetcps.traefik.io"]]' \
  "$(jq '.ingress_routes = ["ingressroutes.traefik.io", "ingressroutetcps.traefik.io"]' <<<"$input" | jq -c -f "$here/needs.jq" |
     jq -c 'select(.right == "write_routes" and .subject == "alice" and .in == "otel") | [.ask.verb, .ask.resource]' | jq -sc 'unique')"

same "the operator is asked to get, list and watch Secrets in every namespace, and to get each by name" \
  '[["cnpg-system","get","secrets"],["cnpg-system","get","secrets/cnpg-ca-secret"],["cnpg-system","list","secrets"],["cnpg-system","watch","secrets"],
    ["databases","get","secrets"],["databases","get","secrets/pg-replication"],["databases","list","secrets"],["databases","watch","secrets"],
    ["otel","get","secrets"],["otel","get","secrets/otel-token"],["otel","list","secrets"],["otel","watch","secrets"]]' \
  "$(jq -c 'select(.right == "operator_reads_secrets_in") | [.in, .ask.verb, .ask.resource]' <<<"$needs" | jq -sc 'unique')"
same "and the plugin the same" \
  '12' "$(jq -c 'select(.right == "plugin_reads_secrets_in") | [.in, .ask.verb, .ask.resource]' <<<"$needs" | jq -s 'unique | length')"

finish
