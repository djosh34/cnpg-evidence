#!/usr/bin/env bash
# Tests listener addresses, process identities and output ordering.
# Usage: bash listening-tcp.jq.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

actual=$(jq -Rn -f "$here/listening-tcp.jq" <<'SS'
LISTEN 0 128 [::]:5432 [::]:* users:(("postgres",pid=42,fd=7))
LISTEN 0 128 127.0.0.1:25 0.0.0.0:*
SS
)
expected=$(cat <<'JSON'
[{"address":"127.0.0.1","port":25,"processes":[]},{"address":"[::]","port":5432,"processes":[{"name":"postgres","pid":42}]}]
JSON
)
same "listening addresses and processes" "$expected" "$actual"

finish
