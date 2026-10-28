#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

# need RIGHT IN SUBJECT VERB RESOURCE ASK_NAMESPACE, and the answer for it.
need() {
  jq -nc --arg right "$1" --arg in "$2" --arg subject "$3" --arg verb "$4" --arg resource "$5" --arg namespace "$6" \
    '{right: $right, in: $in, subject: $subject,
      ask: {verb: $verb, resource: $resource, subresource: "-", namespace: $namespace}}'
}
answer() {
  jq -nc --arg subject "$1" --arg verb "$2" --arg resource "$3" --arg namespace "$4" --argjson allowed "$5" \
    '{subject: $subject, verb: $verb, resource: $resource, subresource: "-", namespace: $namespace, allowed: $allowed,
      reason: (if $allowed then "RBAC: allowed by a binding of \($subject)" else "" end)}'
}

needs=$(
  need superuser_in_cluster_namespace databases alice get secrets/pg-replication databases
  need superuser_in_cluster_namespace databases bob get secrets/pg-replication -
  need superuser_in_cluster_namespace databases bob patch clusters.postgresql.cnpg.io/pg -
  need superuser_in_cluster_namespace databases carol patch pods/pg-1 -
  need create_certificates otel system:serviceaccount:otel:collector create certificates.cert-manager.io otel
  need run_pods otel bob create pods -
  need run_pods otel carol create pods otel
  need write_routes otel carol patch ingresses.networking.k8s.io otel
  need become_cluster_admin "" alice impersonate groups/system:masters -
  need operator_reads_secrets_in kube-system system:serviceaccount:cnpg-system:op list secrets kube-system
)
answers=$(
  answer alice get secrets/pg-replication databases true
  answer bob get secrets/pg-replication - false
  answer bob patch clusters.postgresql.cnpg.io/pg - true
  answer carol patch pods/pg-1 - true
  answer system:serviceaccount:otel:collector create certificates.cert-manager.io otel true
  answer bob create pods - true
  answer carol create pods otel false
  answer carol patch ingresses.networking.k8s.io otel true
  answer alice impersonate groups/system:masters - true
  answer system:serviceaccount:cnpg-system:op list secrets kube-system true
)

# section NEEDS ANSWERS [NOT_SERVED]
section() {
  jq -n --slurpfile needs <(echo "$1") --slurpfile answers <(echo "$2") --argjson not_served "${3:-[]}" \
    '{needs: $needs, answers: $answers, $not_served}' |
    jq -f "$here/kubernetes.jq"
}

expected=$(cat <<'EOF'
{
  "superuser_in_cluster_namespace": ["alice", "bob", "carol"],
  "create_certificates": ["system:serviceaccount:otel:collector"],
  "write_routes": ["carol"],
  "run_pods": ["bob"],
  "become_cluster_admin": ["alice"],
  "operator_reads_secrets_in": ["kube-system"],
  "plugin_reads_secrets_in": []
}
EOF
)
same "subjects per right, namespaces for the Secret scope" \
  "$expected" "$(section "$needs" "$answers" | jq 'del(.granted_by)')"

expected=$(cat <<'EOF'
{
  "superuser_in_cluster_namespace": {
    "alice": ["RBAC: allowed by a binding of alice"],
    "bob": ["RBAC: allowed by a binding of bob"],
    "carol": ["RBAC: allowed by a binding of carol"]
  },
  "operator_reads_secrets_in": {"kube-system": ["RBAC: allowed by a binding of system:serviceaccount:cnpg-system:op"]}
}
EOF
)
same "granted_by has the same shape, with each holder's reasons" \
  "$expected" "$(section "$needs" "$answers" | jq '.granted_by | {superuser_in_cluster_namespace, operator_reads_secrets_in}')"

same "a resource the cluster does not serve is listed" \
  '["ingressroutes.traefik.io"]' "$(section "$needs" "$answers" '["ingressroutes.traefik.io"]' | jq -c .not_served)"

if section "$needs" "$(grep -v carol <<<"$answers")" >/dev/null 2>&1; then
  fail "a missing answer is an error, never a no"
else
  pass "a missing answer is an error, never a no"
fi

finish
