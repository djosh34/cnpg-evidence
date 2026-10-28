#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

# One RoleBinding in databases for alice, a group with a space and a user with
# quotes; the API server says yes only to them reading pg-replication there
# and to cluster-admin.
kubectl() {
  case "$*" in
    "get rolebindings --all-namespaces -o json")
      echo '{"items": [{"metadata": {"namespace": "databases"}, "subjects": [{"kind": "User", "name": "alice"},
                {"kind": "Group", "name": "db admins"}, {"kind": "User", "name": "o'"'"'brien \"x\""}]}]}' ;;
    "get clusterrolebindings -o json")
      echo '{"items": [{"metadata": {}, "subjects": [{"kind": "Group", "name": "system:masters"}]}]}' ;;
    "get namespaces -o json")
      echo '{"items": [{"metadata": {"name": "databases"}}, {"metadata": {"name": "cnpg-system"}}]}' ;;
    "get nodes -o json")
      echo '{"items": [{"metadata": {"name": "node-a"}}]}' ;;
    "get secrets --all-namespaces -o json")
      echo '{"items": [{"metadata": {"namespace": "databases", "name": "pg-replication"}}]}' ;;
    "api-resources --api-group=traefik.io -o name") ;;
    "create -o json -f -")
      jq -c '.items[]
             | .spec.resourceAttributes as $a
             | ($a.verb == "get" and $a.resource == "secrets" and $a.name == "pg-replication"
                and $a.namespace == "databases") as $read
             | .status = if .spec.groups[0] == "system:masters" then {allowed: true}
                         elif $read and (.spec.user | IN("alice", "o'"'"'brien \"x\""))
                           then {allowed: true, reason: "RBAC: allowed by RoleBinding \"read/databases\""}
                         elif $read and .spec.groups == ["db admins", "system:authenticated"]
                           then {allowed: true, reason: "RBAC: allowed by RoleBinding \"admins/databases\""}
                         else {allowed: false} end' ;;
    *) return 1 ;;
  esac
}
export -f kubectl

section=$(bash "$here/kubernetes.sh" databases pg cnpg-system op plug cert-manager pg-1)

same "alice, a spaced group and a quoted user read pg-replication" \
  '["alice", "group:db admins", "group:system:masters", "o'"'"'brien \"x\""]' \
  "$(jq .superuser_in_cluster_namespace <<<"$section")"
same "cluster-admin holds every right" \
  '["group:system:masters"]' "$(jq .become_cluster_admin <<<"$section")"
same "the operator reads no secrets" '[]' "$(jq .operator_reads_secrets_in <<<"$section")"
same "the reasons name the bindings" \
  '{"alice": ["RBAC: allowed by RoleBinding \"read/databases\""], "group:db admins": ["RBAC: allowed by RoleBinding \"admins/databases\""],
    "group:system:masters": [""], "o'"'"'brien \"x\"": ["RBAC: allowed by RoleBinding \"read/databases\""]}' \
  "$(jq '.granted_by.superuser_in_cluster_namespace' <<<"$section")"
same "Traefik's IngressRoute and IngressRouteTCP are not served here" '["ingressroutes.traefik.io","ingressroutetcps.traefik.io"]' \
  "$(jq -c .not_served <<<"$section")"

# Traefik serves both route kinds; tcp-updater may only update and
# tcp-patcher only patch IngressRouteTCPs, in any namespace.
kubectl() {
  case "$*" in
    "get rolebindings --all-namespaces -o json") echo '{"items": []}' ;;
    "get clusterrolebindings -o json")
      echo '{"items": [{"metadata": {}, "subjects": [{"kind": "User", "name": "tcp-updater"}, {"kind": "User", "name": "tcp-patcher"}]}]}' ;;
    "get namespaces -o json") echo '{"items": [{"metadata": {"name": "databases"}}]}' ;;
    "get nodes -o json" | "get secrets --all-namespaces -o json") echo '{"items": []}' ;;
    "api-resources --api-group=traefik.io -o name")
      printf '%s\n' ingressroutes.traefik.io ingressroutetcps.traefik.io middlewares.traefik.io ;;
    "create -o json -f -")
      jq -c '.items[]
             | .spec.resourceAttributes as $a
             | .status.allowed = ($a.resource == "ingressroutetcps" and $a.group == "traefik.io"
                                  and ([.spec.user, $a.verb] | IN(["tcp-updater", "update"], ["tcp-patcher", "patch"])))' ;;
    *) return 1 ;;
  esac
}
export -f kubectl
section=$(bash "$here/kubernetes.sh" databases pg cnpg-system op plug cert-manager pg-1)
same "an update-only and a patch-only holder of IngressRouteTCPs can write routes" '["tcp-patcher","tcp-updater"]' \
  "$(jq -c .write_routes <<<"$section")"
same "with both routes served, nothing is listed as not served" null "$(jq -c .not_served <<<"$section")"

kubectl() {
  case "$*" in
    "create -o json -f -") echo 'Error from server (Forbidden)' >&2; return 1 ;;
    "get namespaces -o json") echo '{"items": [{"metadata": {"name": "databases"}}]}' ;;
    *) echo '{"items": []}' ;;
  esac
}
export -f kubectl
code=0
bash "$here/kubernetes.sh" databases pg cnpg-system op plug cert-manager pg-1 >/dev/null 2>&1 || code=$?
if ((code != 0)); then
  pass "a failed review fails the section"
else
  fail "a failed review fails the section"
fi

kubectl() {
  case "$*" in
    "create -o json -f -") return 1 ;;
    *) echo '{"items": []}' ;;
  esac
}
export -f kubectl
same "no question, no review call" '[]' \
  "$(bash "$here/kubernetes.sh" databases pg cnpg-system op plug cert-manager pg-1 | jq -c .become_cluster_admin)"

finish
