#!/usr/bin/env bash
# Tests the low-port threshold, file capabilities and missing tools.
# Usage: bash low-ports.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

getcap() { echo '/usr/bin/ping cap_net_raw=ep'; }
export -f getcap
same "both parts pass" '{"id":"low-ports","ok":true,"value":"none"}' \
  "$(bash "$here/low-ports.sh" /dev/stdin <<<1024 | jq '{id,ok,value}')"
same_text "higher threshold passes" none "$(bash "$here/low-ports.sh" /dev/stdin <<<2048 | jq -r .value)"
same_text "low threshold fails" 'ip_unprivileged_port_start = 0' "$(bash "$here/low-ports.sh" /dev/stdin <<<0 | jq -r .value)"
getcap() { echo '/opt/bin/server cap_net_bind_service=ep'; }
export -f getcap
same_text "capability fails" '/opt/bin/server cap_net_bind_service=ep' "$(bash "$here/low-ports.sh" /dev/stdin <<<1024 | jq -r .value)"
same_text "both failures joined" 'ip_unprivileged_port_start = 0; /opt/bin/server cap_net_bind_service=ep' "$(bash "$here/low-ports.sh" /dev/stdin <<<0 | jq -r .value)"
command() {
  if [[ $* == '-v getcap' ]]; then return 1; fi
  builtin command "$@"
}
export -f command
same_text "missing getcap fails" 'getcap not found' "$(bash "$here/low-ports.sh" /dev/stdin <<<1024 | jq -r .value)"
unset -f command
status=0
output=$(bash "$here/low-ports.sh" /dev/stdin <<<invalid 2>/dev/null) || status=$?
same_text "invalid threshold exit" 2 "$status"
same_text "invalid threshold stdout" '' "$output"
getcap() { return 7; }
export -f getcap
status=0
output=$(bash "$here/low-ports.sh" /dev/stdin <<<1024) || status=$?
same_text "capability collection error" 7 "$status"
same_text "collection error stdout" '' "$output"

finish
