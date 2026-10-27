#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

# Two needs share one question; a user, a group and a ServiceAccount.
needs='
{"right": "read_secret pg-replication", "in": "databases", "subject": "alice",
 "ask": {"verb": "get", "resource": "secrets/pg-replication", "subresource": "-", "namespace": "databases"}}
{"right": "read_secret pg-replication", "in": "databases", "subject": "alice",
 "ask": {"verb": "get", "resource": "secrets/pg-replication", "subresource": "-", "namespace": "databases"}}
{"right": "exec_into_pods", "in": "databases", "subject": "group:db admins",
 "ask": {"verb": "create", "resource": "pods/pg-1", "subresource": "exec", "namespace": "-"}}
{"right": "change clusters", "in": "databases", "subject": "system:serviceaccount:otel:collector",
 "ask": {"verb": "patch", "resource": "clusters.postgresql.cnpg.io/pg", "subresource": "-", "namespace": "databases"}}
{"right": "impersonate", "in": "", "subject": "alice",
 "ask": {"verb": "impersonate", "resource": "groups/system:masters", "subresource": "-", "namespace": "-"}}
'

expected=$(cat <<'EOF'
{"apiVersion": "v1", "kind": "List", "items": [
  {"apiVersion": "authorization.k8s.io/v1", "kind": "SubjectAccessReview",
   "spec": {"user": "alice", "groups": ["system:authenticated"],
            "resourceAttributes": {"verb": "get", "resource": "secrets", "group": "", "name": "pg-replication", "namespace": "databases"}}},
  {"apiVersion": "authorization.k8s.io/v1", "kind": "SubjectAccessReview",
   "spec": {"user": "alice", "groups": ["system:authenticated"],
            "resourceAttributes": {"verb": "impersonate", "resource": "groups", "group": "", "name": "system:masters"}}},
  {"apiVersion": "authorization.k8s.io/v1", "kind": "SubjectAccessReview",
   "spec": {"user": "evidence-group-probe", "groups": ["db admins", "system:authenticated"],
            "resourceAttributes": {"verb": "create", "resource": "pods", "group": "", "name": "pg-1", "subresource": "exec"}}},
  {"apiVersion": "authorization.k8s.io/v1", "kind": "SubjectAccessReview",
   "spec": {"user": "system:serviceaccount:otel:collector",
            "groups": ["system:serviceaccounts", "system:serviceaccounts:otel", "system:authenticated"],
            "resourceAttributes": {"verb": "patch", "resource": "clusters", "group": "postgresql.cnpg.io", "name": "pg",
                                   "namespace": "databases"}}}
]}
EOF
)
# The order of the items does not matter.
same "one review per distinct question, with the subject's groups" \
  "$(jq '.items |= sort' <<<"$expected")" "$(jq -s -f "$here/reviews.jq" <<<"$needs" | jq '.items |= sort')"

finish
