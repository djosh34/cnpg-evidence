#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

kubectl() {
  case "$*" in
    "get cluster pg -n databases -o jsonpath={.status.certificates.clientCASecret}")
      echo -n client-ca ;;
    "get secret client-ca -n databases -o jsonpath={.data.ca\.crt}")
      base64 -w0 <<'EOF' ;;
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
EOF
    *) return 1 ;;
  esac
}
export -f kubectl

expected=$(cat <<'EOF'
{
  "secret": "client-ca",
  "certificates": [{"name": "CN=example-ca",
                    "sha256_fingerprint": "2E:18:DB:8B:38:5D:21:DA:E1:BB:0C:63:A0:4F:1F:E1:4B:9F:1F:D9:D3:9D:44:C5:69:13:1D:63:9A:66:27:AE"}]
}
EOF
)
same "the Secret named in the Cluster status and its certificates" \
  "$expected" "$(bash "$here/client-ca.sh" databases pg)"

if bash "$here/client-ca.sh" databases other >/dev/null 2>&1; then
  fail "a failed read fails"
else
  pass "a failed read fails"
fi

finish
