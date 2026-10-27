#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../lib/test.sh"

values='{"cluster": {"name": "pg", "namespace": "databases", "instances": 3}, "caSecret": "client-ca",
         "rwLoadBalancer": {"name": "pg-rw-lb"}, "network": {"operatorNamespace": "cnpg-system", "otelNamespace": "otel"},
         "replication": {"commonName": "pg-replication"}, "databases": []}'

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
  out=$(bash "$here/evidence.sh" "$@" <<<"$input" 2>/dev/null) || code=$?
  same_text "$name: exit code" "$want" "$code"
  same_text "$name: nothing on stdout" "" "$out"
}

# refused NAME FILTER: values changed by a jq filter stop before any kubectl call.
refused() {
  local errors
  errors=$(bash "$here/evidence.sh" --ca <(echo "$ca") <<<"$(jq -c "$2" <<<"$values")" 2>&1 >/dev/null) || true
  if [[ $errors == *"the desired state needs"* ]]; then pass "$1"; else fail "$1"; fi
}

kubectl() { echo 'Error from server (Forbidden): secrets is forbidden' >&2; return 1; }
export -f kubectl

exits "no --ca" 2 "$values"
exits "values that are not JSON" 2 "cluster: pg" --ca <(echo "$ca")
exits "values without the cluster" 2 '{}' --ca <(echo "$ca")
exits "a CA file without certificates" 2 "$values" --ca /dev/null
exits "a forbidden read" 2 "$values" --ca <(echo "$ca")

refused "values without cluster.name and the operator namespace" 'del(.cluster.name, .network.operatorNamespace)'
refused "instances that are not a number" '.cluster.instances = "3"'
refused "a database without clientCNs" '.databases = [{name: "orders", role: "orders"}]'
if bash "$here/evidence.sh" --ca <(echo "$ca") <<<"$values" 2>&1 >/dev/null | grep -q "the desired state needs"; then
  fail "complete values pass the check"
else
  pass "complete values pass the check"
fi

# A whole run, with each part replaced by a stub that prints fixed facts.
copy=$(mktemp -d)
trap 'rm -rf "$copy"' EXIT
cp -r "$here/.." "$copy/scripts"
stub() { printf "echo '%s'\n" "$2" >"$copy/scripts/evidence/$1"; }
stub pods/pods.sh '{"primary": "pg-1", "instances": ["pg-1"], "sharing_host_uids": []}'
stub postgres/postgres.sh '{"superusers": ["postgres"]}'
stub logins/logins.sh '{"databases": {}, "details": {"pg_hba": [{"number": 1, "line": "host all all all reject"}]}}'
stub client-ca/client-ca.sh '{"secret": "client-ca", "certificates": []}'
stub tls/tls.sh '{"pg-1": {"postgresql": "TLSv1.3", "metrics": "TLSv1.3"}}'
stub network/network.sh '{}'
stub host-network/host-network.sh '[]'
stub software/software.sh '{"postgresql": "17.1"}'
stub kubernetes/kubernetes.sh '{"namespaces": {}, "granted_by": {}}'
# The stub expands $violations when it runs.
# shellcheck disable=SC2016
printf 'cat >/dev/null\necho "${violations:-[]}"\n' >"$copy/scripts/evidence/violations/violations.sh"
date() { echo 2026-01-02T03:04:05Z; }
export -f date

code=0
out=$(bash "$copy/scripts/evidence/evidence.sh" --ca <(echo "$ca") <<<"$values" 2>/dev/null) || code=$?
same_text "a clean run exits 0" 0 "$code"
same_text "the document starts with what it is, when and where it was read" \
  "kind source collected_at cluster status violations postgres databases client_ca tls network_policy kubernetes pods_sharing_host_uids host_network_pods_that_can_bind_low_ports software details" \
  "$(jq -r 'keys_unsorted | join(" ")' <<<"$out")"
same "header values" \
  '{"kind": "actual", "source": "evidence", "collected_at": "2026-01-02T03:04:05Z", "cluster": {"name": "pg", "namespace": "databases"}, "status": "pass", "violations": []}' \
  "$(jq '{kind, source, collected_at, cluster, status, violations}' <<<"$out")"
same "details keep the primary, the instances and the numbered lines" \
  '{"primary": "pg-1", "instances": ["pg-1"], "pg_hba": [{"number": 1, "line": "host all all all reject"}]}' \
  "$(jq .details <<<"$out")"

code=0
out=$(violations='["rule 4: role app exists"]' bash "$copy/scripts/evidence/evidence.sh" --ca <(echo "$ca") <<<"$values" 2>/dev/null) || code=$?
same_text "a run with violations exits 1" 1 "$code"
same "a run with violations fails" '{"status": "fail", "violations": ["rule 4: role app exists"]}' \
  "$(jq '{status, violations}' <<<"$out")"

finish
