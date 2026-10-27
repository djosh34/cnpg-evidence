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

finish
