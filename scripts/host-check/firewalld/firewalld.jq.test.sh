#!/usr/bin/env bash
# Tests conversion of firewalld zone output to JSON lists.
# Usage: bash firewalld.jq.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

actual=$(jq -n --arg zone public --arg target default --arg interfaces 'eth0 eth1' \
  --arg sources '' --arg services 'ssh' --arg ports '443/tcp' --arg rich_rules $'rule one\nrule two' \
  -f "$here/firewalld.jq")
expected=$(cat <<'JSON'
{"zone":"public","target":"default","interfaces":["eth0","eth1"],"sources":[],"services":["ssh"],"ports":["443/tcp"],"rich_rules":["rule one","rule two"]}
JSON
)
same "zone lists" "$expected" "$actual"

finish
