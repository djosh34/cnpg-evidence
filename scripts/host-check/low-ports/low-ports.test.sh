#!/usr/bin/env bash
# Tests the low-port threshold, and that no file capability is read.
# Usage: bash low-ports.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

# A file with cap_net_bind_service no longer fails the check.
getcap() { echo '/opt/bin/server cap_net_bind_service=ep'; }
export -f getcap
same "threshold 1024 passes" '{"id":"low-ports","ok":true,"value":"none","raw":"ip_unprivileged_port_start = 1024"}' \
  "$(bash "$here/low-ports.sh" /dev/stdin <<<1024)"
same_text "higher threshold passes" none "$(bash "$here/low-ports.sh" /dev/stdin <<<2048 | jq -r .value)"
same_text "low threshold fails" 'ip_unprivileged_port_start = 0' "$(bash "$here/low-ports.sh" /dev/stdin <<<0 | jq -r .value)"
status=0
output=$(bash "$here/low-ports.sh" /dev/stdin <<<invalid 2>/dev/null) || status=$?
same_text "invalid threshold exit" 2 "$status"
same_text "invalid threshold stdout" '' "$output"

finish
