#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

# The kubernetes facts of a clean cluster with Traefik.
facts=$(cat <<'JSON'
{"kubernetes": {
  "superuser_in_cluster_namespace":["group:system:masters","system:serviceaccount:kube-system:traefik"],
  "create_certificates":["group:system:masters","system:serviceaccount:kube-system:helm-traefik"],
  "write_routes":["group:system:masters"],"run_pods":["group:system:masters"],"become_cluster_admin":["group:system:masters"],
  "operator_reads_secrets_in":["cnpg-system","databases"],"plugin_reads_secrets_in":["databases"]}}
JSON
)

values=$(cat <<'EOF'
{"cluster": {"name": "pg", "namespace": "databases", "instances": 3}, "caSecret": "client-ca",
 "rwLoadBalancer": {"name": "pg-rw-lb"}, "network": {"operatorNamespace": "cnpg-system"},
 "replication": {"commonName": "pg-replication"},
 "databases": [{"name": "orders", "role": "orders", "clientCNs": ["orders-app.test"]},
               {"name": "billing", "role": "billing", "clientCNs": ["billing-app.test", "billing-report.test"]}]}
EOF
)

# violations FILTER: the sentences for the clean facts changed by a jq filter.
violations() {
  jq -c "$1" <<<"$facts" |
    jq --slurpfile values <(echo "$values") \
      '{facts: ., values: $values[0], operator_account: "cnpg-cloudnative-pg", plugin_account: "barman-cloud-plugin-barman-cloud"}' |
    jq -L "$here" -f "$here/kubernetes.jq"
}

same "the clean cluster has none" '[]' "$(violations .)"

same "secret read in kube-system through the operator namespace group" \
  '["rule 6: the operator can read secrets in kube-system", "rule 6: the barman-cloud plugin can read secrets in kube-system"]' \
  "$(violations '.kubernetes.operator_reads_secrets_in += ["kube-system"] | .kubernetes.plugin_reads_secrets_in += ["kube-system"]')"

same "a user with every right" \
  '["rule 7: mallory can get PostgreSQL superuser through rights in databases",
    "rule 7: mallory can create Certificates or CertificateRequests",
    "rule 7: mallory can write Ingresses, IngressRoutes or IngressRouteTCPs",
    "rule 7: mallory can run pods", "rule 7: mallory can become cluster-admin"]' \
  "$(violations '.kubernetes |= with_entries(if .key | endswith("_reads_secrets_in") then . else .value += ["mallory"] end)')"

same "Traefik may read Secrets, but not run pods" \
  '["rule 7: system:serviceaccount:kube-system:traefik can run pods"]' \
  "$(violations '.kubernetes.run_pods += ["system:serviceaccount:kube-system:traefik"]')"

same "the operator may hold superuser rights, but not create certificates" \
  '["rule 7: system:serviceaccount:cnpg-system:cnpg-cloudnative-pg can create Certificates or CertificateRequests"]' \
  "$(violations '.kubernetes.superuser_in_cluster_namespace += ["system:serviceaccount:cnpg-system:cnpg-cloudnative-pg"]
                 | .kubernetes.create_certificates += ["system:serviceaccount:cnpg-system:cnpg-cloudnative-pg"]')"

# violations_because FILTER GRANTED_BY: the same, with the reasons of the kubernetes section.
violations_because() {
  jq -c "$1" <<<"$facts" |
    jq --slurpfile values <(echo "$values") --argjson granted_by "$2" \
      '{facts: ., values: $values[0], granted_by: $granted_by,
        operator_account: "cnpg-cloudnative-pg", plugin_account: "barman-cloud-plugin-barman-cloud"}' |
    jq -L "$here" -f "$here/kubernetes.jq"
}

same "each sentence names the binding that allowed it" \
  '["rule 7: mallory can get PostgreSQL superuser through rights in databases (allowed by RoleBinding \"mallory/databases\" of Role \"secrets\" to User \"mallory\")",
    "rule 6: the operator can read secrets in kube-system (allowed by ClusterRoleBinding \"a\" of ClusterRole \"view\" to Group \"system:serviceaccounts:cnpg-system\"; allowed by RoleBinding \"b/kube-system\" of Role \"r\" to ServiceAccount \"cnpg-cloudnative-pg/cnpg-system\")"]' \
  "$(violations_because '.kubernetes.superuser_in_cluster_namespace += ["mallory"]
                         | .kubernetes.operator_reads_secrets_in += ["kube-system"]' \
     '{"superuser_in_cluster_namespace": {"mallory": ["RBAC: allowed by RoleBinding \"mallory/databases\" of Role \"secrets\" to User \"mallory\""]},
       "operator_reads_secrets_in": {"kube-system": ["RBAC: allowed by ClusterRoleBinding \"a\" of ClusterRole \"view\" to Group \"system:serviceaccounts:cnpg-system\"",
                                                    "RBAC: allowed by RoleBinding \"b/kube-system\" of Role \"r\" to ServiceAccount \"cnpg-cloudnative-pg/cnpg-system\""]}}')"

finish
