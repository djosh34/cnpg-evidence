#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

# Reviews as the API server returns them: empty strings left out, the reason
# only where it gives one.
reviews='
{"spec": {"user": "alice", "groups": ["system:authenticated"],
          "resourceAttributes": {"verb": "get", "resource": "secrets", "name": "pg-replication", "namespace": "databases"}},
 "status": {"allowed": true, "reason": "RBAC: allowed by RoleBinding \"read/databases\" of Role \"read\" to User \"alice\""}}
{"spec": {"user": "evidence-group-probe", "groups": ["db admins", "system:authenticated"],
          "resourceAttributes": {"verb": "create", "resource": "pods", "name": "pg-1", "subresource": "exec"}},
 "status": {"allowed": false}}
{"spec": {"user": "evidence-group-probe", "groups": ["system:authenticated"],
          "resourceAttributes": {"verb": "list", "resource": "clusters", "group": "postgresql.cnpg.io", "namespace": "databases"}},
 "status": {"allowed": false}}
'

expected=$(cat <<'EOF'
[
  {"subject": "alice", "verb": "get", "resource": "secrets/pg-replication", "subresource": "-", "namespace": "databases",
   "allowed": true, "reason": "RBAC: allowed by RoleBinding \"read/databases\" of Role \"read\" to User \"alice\""},
  {"subject": "group:db admins", "verb": "create", "resource": "pods/pg-1", "subresource": "exec", "namespace": "-",
   "allowed": false, "reason": ""},
  {"subject": "evidence-group-probe", "verb": "list", "resource": "clusters.postgresql.cnpg.io", "subresource": "-",
   "namespace": "databases", "allowed": false, "reason": ""}
]
EOF
)
same "questions as needs.jq asks them, a user named like the probe stays a user" \
  "$expected" "$(jq -s -f "$here/answers.jq" <<<"$reviews" | jq -s .)"

needs='{"right": "x", "in": "databases", "subject": "group:db admins",
        "ask": {"verb": "create", "resource": "clusters.postgresql.cnpg.io/pg", "subresource": "status", "namespace": "databases"}}'
question=$(jq -c '.ask + {subject}' <<<"$needs")
same "a review of reviews.jq answers its own question" "$question" \
  "$(jq -s -f "$here/reviews.jq" <<<"$needs" | jq '.items[] | .status = {allowed: false}' |
     jq -s -f "$here/answers.jq" | jq -c 'del(.allowed, .reason)')"

finish
