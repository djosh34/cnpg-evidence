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
    "get networkpolicies -n databases -o json")
      echo '{"items": [{"metadata": {"name": "pg-ingress"}}]}' ;;
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
  '{"pg-replication": ["alice", "group:db admins", "group:system:masters", "o'"'"'brien \"x\""], "all (list)": ["group:system:masters"], "all (watch)": ["group:system:masters"]}' \
  "$(jq .namespaces.databases.read_secret <<<"$section")"
same "cluster-admin holds every right" \
  '["group:system:masters"]' "$(jq .namespaces.databases.exec_into_pods <<<"$section")"
same "the operator reads no secrets" '[]' "$(jq .operator_reads_secrets_in <<<"$section")"
same "the reasons name the bindings" \
  '{"alice": ["RBAC: allowed by RoleBinding \"read/databases\""], "group:db admins": ["RBAC: allowed by RoleBinding \"admins/databases\""],
    "group:system:masters": [""], "o'"'"'brien \"x\"": ["RBAC: allowed by RoleBinding \"read/databases\""]}' \
  "$(jq '.granted_by.namespaces.databases.read_secret["pg-replication"]' <<<"$section")"
same "Traefik's IngressRoute is not served here" '["ingressroutes.traefik.io"]' "$(jq -c .not_served <<<"$section")"

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
  "$(bash "$here/kubernetes.sh" databases pg cnpg-system op plug cert-manager pg-1 | jq -c .impersonate)"

finish
