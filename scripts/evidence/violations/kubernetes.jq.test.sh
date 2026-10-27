#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

# The kubernetes facts of a clean cluster, cut short.
facts=$(cat <<'JSON'
{"kubernetes": {
  "namespaces": {
    "databases": {"exec_into_pods":["group:system:masters"],"change_pods":["group:system:masters"],"run_pods":["group:system:masters"],
                  "read_secret":{"pg-replication":["group:system:masters"],"all (list)":["group:system:masters"]},
                  "write_secret":{"all (create)":["group:system:masters"],"client-ca":["group:system:masters"]},
                  "create_pg_tokens":["group:system:masters"],"change":{"clusters":["group:system:masters"],"networkpolicies":["group:system:masters"],"endpointslices":["group:system:masters"]}},
    "cert-manager": {"exec_into_pods":[],"change_pods":[],"run_pods":[],
                     "read_secret":{"cert-manager-webhook-ca":["system:serviceaccount:cert-manager:cert-manager-webhook"]},
                     "write_secret":{"cert-manager-webhook-ca":["system:serviceaccount:cert-manager:cert-manager-webhook"]}}
  },
  "request_certificates":["group:system:masters"],"proxy_to_nodes":["group:system:masters"],"impersonate":["group:system:masters"],
  "bind_or_escalate_roles":["group:system:masters"],"change_webhooks":["group:system:masters"],"can_open_node_ports":["group:system:masters"],
  "operator_reads_secrets_in":["cnpg-system","databases"],"plugin_reads_secrets_in":["databases"]}}
JSON
)

values=$(cat <<'EOF'
{"cluster": {"name": "pg", "namespace": "databases", "instances": 3}, "caSecret": "client-ca",
 "rwLoadBalancer": {"name": "pg-rw-lb"}, "network": {"operatorNamespace": "cnpg-system", "otelNamespace": "otel"},
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
  '["rule 7: the operator can read secrets in kube-system", "rule 7: the barman-cloud plugin can read secrets in kube-system"]' \
  "$(violations '.kubernetes.operator_reads_secrets_in += ["kube-system"] | .kubernetes.plugin_reads_secrets_in += ["kube-system"]')"

same "a user that can create pods" \
  '["rule 8: mallory can create or change pods or workloads in databases", "rule 8: mallory can open ports on the nodes"]' \
  "$(violations '.kubernetes.namespaces.databases.run_pods += ["mallory"] | .kubernetes.can_open_node_ports += ["mallory"]')"

same "pod patch, Secret writes, NetworkPolicy delete and EndpointSlice changes" \
  '["rule 8: mallory can change pods in databases", "rule 8: mallory can create secrets in databases",
    "rule 8: mallory can change secret client-ca in databases", "rule 8: mallory can change networkpolicies in databases",
    "rule 8: mallory can change endpointslices in databases"]' \
  "$(violations '.kubernetes.namespaces.databases |= (.change_pods += ["mallory"] | .write_secret["all (create)"] += ["mallory"]
                 | .write_secret["client-ca"] += ["mallory"] | .change.networkpolicies += ["mallory"]
                 | .change.endpointslices += ["mallory"])')"

same "the webhook may keep its own CA only in cert-manager" \
  '["rule 8: system:serviceaccount:cert-manager:cert-manager-webhook can get secret pg-replication in databases"]' \
  "$(violations '.kubernetes.namespaces.databases.read_secret["pg-replication"] += ["system:serviceaccount:cert-manager:cert-manager-webhook"]')"

same "exec into cert-manager's pods" '["rule 8: mallory can exec into pods in cert-manager"]' \
  "$(violations '.kubernetes.namespaces["cert-manager"].exec_into_pods += ["mallory"]')"

same "secret read and certificates" \
  '["rule 8: system:serviceaccount:otel:collector can get secret pg-replication in databases", "rule 8: system:serviceaccount:new:issuer can request certificates"]' \
  "$(violations '.kubernetes.namespaces.databases.read_secret["pg-replication"] += ["system:serviceaccount:otel:collector"]
                 | .kubernetes.request_certificates += ["system:serviceaccount:new:issuer"]')"

same "the operator may hold superuser rights, but not request certificates" \
  '["rule 8: system:serviceaccount:cnpg-system:cnpg-cloudnative-pg can request certificates"]' \
  "$(violations '.kubernetes.namespaces.databases.exec_into_pods += ["system:serviceaccount:cnpg-system:cnpg-cloudnative-pg"]
                 | .kubernetes.request_certificates += ["system:serviceaccount:cnpg-system:cnpg-cloudnative-pg"]')"

# violations_because FILTER GRANTED_BY: the same, with the reasons of the kubernetes section.
violations_because() {
  jq -c "$1" <<<"$facts" |
    jq --slurpfile values <(echo "$values") --argjson granted_by "$2" \
      '{facts: ., values: $values[0], granted_by: $granted_by,
        operator_account: "cnpg-cloudnative-pg", plugin_account: "barman-cloud-plugin-barman-cloud"}' |
    jq -L "$here" -f "$here/kubernetes.jq"
}

same "each sentence names the binding that allowed it" \
  '["rule 8: mallory can change secret client-ca in databases (allowed by RoleBinding \"mallory/databases\" of Role \"secrets\" to User \"mallory\")",
    "rule 7: the operator can read secrets in kube-system (allowed by ClusterRoleBinding \"a\" of ClusterRole \"view\" to Group \"system:serviceaccounts:cnpg-system\"; allowed by RoleBinding \"b/kube-system\" of Role \"r\" to ServiceAccount \"cnpg-cloudnative-pg/cnpg-system\")"]' \
  "$(violations_because '.kubernetes.namespaces.databases.write_secret["client-ca"] += ["mallory"]
                         | .kubernetes.operator_reads_secrets_in += ["kube-system"]' \
     '{"namespaces": {"databases": {"write_secret": {"client-ca": {"mallory": ["RBAC: allowed by RoleBinding \"mallory/databases\" of Role \"secrets\" to User \"mallory\""]}}}},
       "operator_reads_secrets_in": {"kube-system": ["RBAC: allowed by ClusterRoleBinding \"a\" of ClusterRole \"view\" to Group \"system:serviceaccounts:cnpg-system\"",
                                                    "RBAC: allowed by RoleBinding \"b/kube-system\" of Role \"r\" to ServiceAccount \"cnpg-cloudnative-pg/cnpg-system\""]}}')"

finish
