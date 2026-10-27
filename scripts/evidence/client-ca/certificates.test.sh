#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

# A self-signed example CA.
pem=$(cat <<'EOF'
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
)

expected=$(cat <<'EOF'
[{"name": "CN=example-ca",
  "sha256_fingerprint": "2E:18:DB:8B:38:5D:21:DA:E1:BB:0C:63:A0:4F:1F:E1:4B:9F:1F:D9:D3:9D:44:C5:69:13:1D:63:9A:66:27:AE"}]
EOF
)
same "one certificate" "$expected" "$(bash "$here/certificates.sh" <<<"$pem")"

twice=$(printf '%s\nsome text between\n%s' "$pem" "$pem")
same "every certificate in the text counts" \
  "$(jq '. + .' <<<"$expected")" "$(bash "$here/certificates.sh" <<<"$twice")"

same "no certificate is an empty list" "[]" "$(bash "$here/certificates.sh" </dev/null)"

finish
