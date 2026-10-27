#!/usr/bin/env bash
# Tests k3s setting selection and multiline unit flags.
# Usage: bash k3s-config.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

sed() {
  builtin command sed "${@:1:$#-1}" <<'YAML'
# Only safe settings leave the file.
token: secret
selinux: true # enabled
  disable-network-policy: false
YAML
}
awk() {
  builtin command awk "${@:1:$#-1}" <<'UNIT'
[Service]
ExecStart=/usr/local/bin/k3s server \
  '--selinux' \
  '--disable-network-policy=false' \
  '--token=secret'
Environment=K3S_TOKEN=secret
UNIT
}
export -f sed awk
actual=$(bash "$here/k3s-config.sh" "$here/k3s-config.test.sh" "$here/k3s-config.sh")
expected=$(cat <<JSON
{"$here/k3s-config.test.sh":["selinux: true","disable-network-policy: false"],"$here/k3s-config.sh":["--selinux","--disable-network-policy=false"]}
JSON
)
same "safe settings and multiline unit flags" "$expected" "$actual"
actual=$(bash "$here/k3s-config.sh" /no-such-config "$here/k3s-config.sh" "$here/k3s-config.test.sh")
expected=$(cat <<JSON
{"$here/k3s-config.sh":["--selinux","--disable-network-policy=false"],"$here/k3s-config.test.sh":["--selinux","--disable-network-policy=false"]}
JSON
)
same "server and agent units" "$expected" "$actual"
same "absent files" '{}' "$(bash "$here/k3s-config.sh" /no-such-config /no-such-unit)"

finish
