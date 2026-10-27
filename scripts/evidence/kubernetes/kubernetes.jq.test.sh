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
  need "read_secret pg-replication" databases alice get secrets/pg-replication databases
  need "read_secret pg-replication" databases bob get secrets/pg-replication -
  need "write_secret all (create)" cnpg-system bob create secrets -
  need "write_secret cnpg-ca-secret" cnpg-system bob patch secrets/cnpg-ca-secret -
  need "change clusters" databases alice patch clusters.postgresql.cnpg.io/pg databases
  need change_pods databases carol patch pods/pg-1 -
  need create_certificates otel system:serviceaccount:otel:collector create certificates.cert-manager.io otel
  need run_pods otel bob create pods -
  need run_pods databases bob create pods -
  need run_pods otel carol create pods otel
  need change_services databases alice create services databases
  need change_ingresses otel carol patch ingresses.networking.k8s.io otel
  need operator_reads_secrets_in kube-system system:serviceaccount:cnpg-system:op list secrets kube-system
  need impersonate "" alice impersonate groups/system:masters -
)
answers=$(
  answer alice get secrets/pg-replication databases true
  answer bob get secrets/pg-replication - false
  answer bob create secrets - false
  answer bob patch secrets/cnpg-ca-secret - true
  answer alice patch clusters.postgresql.cnpg.io/pg databases true
  answer carol patch pods/pg-1 - true
  answer system:serviceaccount:otel:collector create certificates.cert-manager.io otel true
  answer bob create pods - true
  answer carol create pods otel false
  answer alice create services databases true
  answer carol patch ingresses.networking.k8s.io otel true
  answer system:serviceaccount:cnpg-system:op list secrets kube-system true
  answer alice impersonate groups/system:masters - true
)

# section NEEDS ANSWERS [NOT_SERVED]
section() {
  jq -n --slurpfile needs <(echo "$1") --slurpfile answers <(echo "$2") --argjson not_served "${3:-[]}" \
    '{needs: $needs, answers: $answers, namespace: "databases", component_namespaces: ["cnpg-system", "databases"], $not_served}' |
    jq -f "$here/kubernetes.jq"
}

expected=$(cat <<'EOF'
{
  "namespaces": {
    "cnpg-system": {
      "exec_into_pods": [], "change_pods": [], "run_pods": [],
      "read_secret": {},
      "write_secret": {"all (create)": [], "cnpg-ca-secret": ["bob"]}
    },
    "databases": {
      "exec_into_pods": [], "change_pods": ["carol"], "run_pods": ["bob"],
      "read_secret": {"pg-replication": ["alice"]},
      "write_secret": {},
      "create_pg_tokens": [],
      "change": {"clusters": ["alice"]}
    }
  },
  "request_certificates": ["bob", "system:serviceaccount:otel:collector"],
  "proxy_to_nodes": [],
  "impersonate": ["alice"],
  "bind_or_escalate_roles": [],
  "change_webhooks": [],
  "can_open_node_ports": ["alice", "bob", "carol"],
  "operator_reads_secrets_in": ["kube-system"],
  "plugin_reads_secrets_in": []
}
EOF
)
same "subjects per right and namespace; pod creators where a certificate maker's account lives" \
  "$expected" "$(section "$needs" "$answers" | jq 'del(.granted_by)')"

expected=$(cat <<'EOF'
{
  "write_secret": {"all (create)": {}, "cnpg-ca-secret": {"bob": ["RBAC: allowed by a binding of bob"]}},
  "request_certificates": {
    "bob": ["RBAC: allowed by a binding of bob"],
    "system:serviceaccount:otel:collector": ["RBAC: allowed by a binding of system:serviceaccount:otel:collector"]
  },
  "can_open_node_ports": {
    "alice": ["RBAC: allowed by a binding of alice"],
    "bob": ["RBAC: allowed by a binding of bob"],
    "carol": ["RBAC: allowed by a binding of carol"]
  },
  "operator_reads_secrets_in": {"kube-system": ["RBAC: allowed by a binding of system:serviceaccount:cnpg-system:op"]}
}
EOF
)
same "granted_by has the same shape, with each holder's reasons" \
  "$expected" \
  "$(section "$needs" "$answers" | jq '.granted_by | {write_secret: .namespaces["cnpg-system"].write_secret,
                                                       request_certificates, can_open_node_ports, operator_reads_secrets_in}')"

same "a resource the cluster does not serve is listed" \
  '["ingressroutes.traefik.io"]' "$(section "$needs" "$answers" '["ingressroutes.traefik.io"]' | jq -c .not_served)"

if section "$needs" "$(grep -v carol <<<"$answers")" >/dev/null 2>&1; then
  fail "a missing answer is an error, never a no"
else
  pass "a missing answer is an error, never a no"
fi

finish
