#!/usr/bin/env bash
# Checks LoadBalancer IP and hostname targets, port combinations and empty ingress.
# Usage: bash targets.test.sh
# Exit: 0 all assertions pass, 1 an assertion fails, nonzero on a test error.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

actual=$(jq -f "$here/targets.jq" <<'JSON'
{"spec":{"ports":[{"port":5432},{"port":5433}]},"status":{"loadBalancer":{"ingress":[{"ip":"192.0.2.1"},{"hostname":"pg.test"}]}}}
JSON
)
expected=$(cat <<'JSON'
"192.0.2.1:5432"
"pg.test:5432"
"192.0.2.1:5433"
"pg.test:5433"
JSON
)
same 'addresses and ports' "$expected" "$actual"
actual=$(jq -f "$here/targets.jq" <<'JSON'
{"spec":{"ports":[{"port":5432}]},"status":{"loadBalancer":{}}}
JSON
)
same_text 'no addresses' '' "$actual"
finish
