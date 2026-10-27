#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

input=$(cat <<'EOF'
[
  {"kind": "RoleBinding", "metadata": {"name": "a", "namespace": "databases"},
   "subjects": [{"kind": "ServiceAccount", "name": "pg"},
                {"kind": "ServiceAccount", "name": "op", "namespace": "cnpg-system"},
                {"kind": "Group", "name": "system:serviceaccounts:otel"}]},
  {"kind": "ClusterRoleBinding", "metadata": {"name": "b"},
   "subjects": [{"kind": "User", "name": "alice"}, {"kind": "Group", "name": "system:masters"}]},
  {"kind": "ClusterRoleBinding", "metadata": {"name": "no-subjects"}}
]
EOF
)

expected=$(cat <<'EOF'
{
  "subjects": ["alice", "group:system:masters", "group:system:serviceaccounts:otel",
               "system:serviceaccount:cnpg-system:op", "system:serviceaccount:databases:pg"],
  "named_in": {
    "databases": ["group:system:serviceaccounts:otel", "system:serviceaccount:cnpg-system:op",
                  "system:serviceaccount:databases:pg"]
  }
}
EOF
)
same "subject names, and who RoleBindings name per namespace" "$expected" "$(jq -f "$here/subjects.jq" <<<"$input")"

finish
