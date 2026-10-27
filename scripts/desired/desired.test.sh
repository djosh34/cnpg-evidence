#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../lib/test.sh"

values='{"cluster": {"name": "pg", "namespace": "databases", "instances": 3}, "caSecret": "client-ca",
         "rwLoadBalancer": {"name": "pg-rw-lb"}, "network": {"operatorNamespace": "cnpg-system", "otelNamespace": "otel"},
         "replication": {"commonName": "pg-replication"},
         "databases": [{"name": "orders", "role": "orders", "clientCNs": ["orders-app.test"]},
                       {"name": "billing", "role": "billing", "clientCNs": ["billing-report.test", "billing-app.test"]}]}'

# A self-signed example CA.
ca=$(cat <<'PEM'
-----BEGIN CERTIFICATE-----
MIIBkTCCATegAwIBAgIUVdnCsKqQvbtJRmPZ/6u+aojXS60wCgYIKoZIzj0EAwIw
FTETMBEGA1UEAwwKZXhhbXBsZS1jYTAgFw0yNjEwMjYyMjI4NDJaGA8yMTI2MTAw
MjIyMjg0MlowFTETMBEGA1UEAwwKZXhhbXBsZS1jYTBZMBMGByqGSM49AgEGCCqG
SM49AwEHA0IABK96rnXBR1T7LMctYAGlI88Dp7VLinVhVR/oAs3ZC7PEhfykbv/Y
MR11IoXGM8bQH6+HcXXMzwUIeaNyxfmrbomjYzBhMB0GA1UdDgQWBBQs98VwdULw
5fu/22ReAjjasoA1VDAfBgNVHSMEGDAWgBQs98VwdULw5fu/22ReAjjasoA1VDAP
BgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjAKBggqhkjOPQQDAgNIADBF
AiEAz4ap+FRfYVnrCN7mx9FEGKFBGxwdUAREqgZzAIeqonECIGBZ/2a4is7PBGlZ
CNdRtGFbSdX+KuOzRI+Xe0LXs9ju
-----END CERTIFICATE-----
PEM
)

# exits NAME CODE STDIN ARGS...: the exit code, and nothing on stdout.
exits() {
  local name=$1 want=$2 input=$3 code=0 out
  shift 3
  out=$(bash "$here/desired.sh" "$@" <<<"$input" 2>/dev/null) || code=$?
  same_text "$name: exit code" "$want" "$code"
  same_text "$name: nothing on stdout" "" "$out"
}

exits "evidence without --ca" 2 "$values"
exits "--ca for host-check" 2 "$values" --source host-check --ca <(echo "$ca")
exits "an unknown source" 2 "$values" --source versions
exits "--postgres-uid for host-check" 2 "$values" --source host-check --postgres-uid 26
exits "a uid that is not a number" 2 "$values" --source prove --postgres-uid nope
exits "values that are not JSON" 2 "cluster: pg" --source host-check
exits "values without the cluster" 2 '{}' --source host-check
exits "a CA file without certificates" 2 "$values" --ca /dev/null
exits "prove without a database" 2 "$(jq -c '.databases = []' <<<"$values")" --source prove

evidence=$(bash "$here/desired.sh" --ca <(echo "$ca") <<<"$values")
same "evidence: what it is" '{"kind": "desired", "source": "evidence", "cluster": {"name": "pg", "namespace": "databases"}}' \
  "$(jq '{kind, source, cluster}' <<<"$evidence")"
same_text "evidence: no verdict, no collection time and no versions" \
  "cluster postgres databases client_ca tls network_policy kubernetes pods_sharing_host_uids host_network_pods_that_can_bind_low_ports details" \
  "$(jq -r 'del(.kind, .source) | keys_unsorted | join(" ")' <<<"$evidence")"
same "evidence: every role of the values, and only CNPG's roles hold rights" \
  '{"roles": ["billing", "cnpg_metrics_exporter", "orders", "postgres", "streaming_replica"], "have_password": [],
    "superusers": ["postgres"], "can_replicate": ["postgres", "streaming_replica"]}' \
  "$(jq '.postgres | {roles, have_password, superusers, can_replicate}' <<<"$evidence")"
same "evidence: a database of the values, its logins and the default CONNECT" \
  '{"owner": "billing", "connect": ["PUBLIC", "billing"], "logins": {"billing": {"common_names": ["billing-app.test", "billing-report.test"]},
    "cnpg_metrics_exporter": {"os_users": ["postgres"]}, "postgres": {"os_users": ["postgres"]}}}' \
  "$(jq .databases.billing <<<"$evidence")"
same "evidence: the certificates of --ca" '{"secret": "client-ca", "certificates": [{"name": "CN=example-ca",
    "sha256_fingerprint": "2E:18:DB:8B:38:5D:21:DA:E1:BB:0C:63:A0:4F:1F:E1:4B:9F:1F:D9:D3:9D:44:C5:69:13:1D:63:9A:66:27:AE"}]}' \
  "$(jq .client_ca <<<"$evidence")"
same "evidence: every instance pod under *" '{"*": {"postgresql": "TLSv1.3", "metrics": "TLSv1.3"}}' "$(jq .tls <<<"$evidence")"
same "evidence: network sources under *" '["*"]' "$(jq '.network_policy | keys' <<<"$evidence")"
same "evidence: the operator's and OTel's sources are named from the values" '{"cnpg-system operator": [8000], "otel": [9187]}' \
  "$(jq '.network_policy["*"] | {"cnpg-system operator", otel}' <<<"$evidence")"
same "evidence: rights are allowed sets" \
  '{"exec": true, "secrets": true, "webhook only in cert-manager": {"cert-manager": true, "cnpg-system": false, "databases": false}, "operator": ["cnpg-system", "databases"]}' \
  "$(jq '.kubernetes as $k | {
      exec: ($k.namespaces.databases.exec_into_pods.allowed | index("system:serviceaccount:databases:pg") != null),
      secrets: ($k.namespaces.databases.read_secret["*"].allowed | index("group:system:masters") != null),
      "webhook only in cert-manager": ($k.namespaces | map_values(.run_pods.allowed | any(endswith("cert-manager-webhook")))),
      operator: $k.operator_reads_secrets_in.allowed}' <<<"$evidence")"
same_text "evidence: rights in the cluster's namespace only" "change create_pg_tokens" \
  "$(jq -r '[.kubernetes.namespaces | .databases, .["cnpg-system"] | keys - ["exec_into_pods", "change_pods", "run_pods", "read_secret", "write_secret"] | .[]] | join(" ")' <<<"$evidence")"
same "evidence: numbered pg_hba lines with the values' lines before the reject" \
  '[{"number": 6, "line": "hostssl orders orders all cert map=clients clientcert=verify-full"},
    {"number": 7, "line": "hostssl billing billing all cert map=clients clientcert=verify-full"},
    {"number": 8, "line": "host all all all reject"}, {"number": 9, "line": "host all all all scram-sha-256"}]' \
  "$(jq '.details.pg_hba[5:]' <<<"$evidence")"
same "evidence: numbered pg_ident lines, one per CN" \
  '[{"number": 5, "line": "cnpg_streaming_replica pg-replication streaming_replica"}, {"number": 6, "line": "clients orders-app.test orders"},
    {"number": 7, "line": "clients billing-report.test billing"}, {"number": 8, "line": "clients billing-app.test billing"}]' \
  "$(jq '.details.pg_ident[4:]' <<<"$evidence")"

host_check=$(bash "$here/desired.sh" --source host-check <<<"$values")
same_text "host-check: every check in order" \
  "selinux-enforcing postgres-uid-account postgres-gid-group postgres-sudoers postgresql-server-absent storage-dir-mode kubelet-pods-mode k3s-kubeconfig-mode k3s-selinux k3s-network-policy subordinate-ids unprivileged-port-start bind-service-capability" \
  "$(jq -r '[.checks[].id] | join(" ")' <<<"$host_check")"
same "host-check: a row is the passing value" '{"id": "unprivileged-port-start", "ok": true, "value": "1024 or higher"}' \
  "$(jq '.checks[11]' <<<"$host_check")"

prove=$(bash "$here/desired.sh" --source prove --postgres-uid 99 <<<"$values")
same "prove: what it is and where" '{"kind": "desired", "source": "prove", "namespace": "databases", "cluster": "pg"}' \
  "$(jq '{kind, source, namespace, cluster}' <<<"$prove")"
same "prove: the first database is the application login" \
  '{"probe": "tls-no-client-cert", "expected": "refused, orders to orders needs a client certificate", "value": "denied", "ok": true}' \
  "$(jq '.probes[2]' <<<"$prove")"
same "prove: two controls" '["control-replication-cert", "control-other-namespace"]' \
  "$(jq '[.probes[] | select(.value == "allowed") | .probe]' <<<"$prove")"
same_text "prove: uid probes name --postgres-uid" 6 "$(jq '[.probes[] | select(.probe | startswith("uid-99 "))] | length' <<<"$prove")"
same_text "prove: 19 probes" 19 "$(jq '.probes | length' <<<"$prove")"

finish
