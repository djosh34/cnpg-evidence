#!/usr/bin/env bash
# Tests the low-port threshold and invalid input.
# Usage: bash unprivileged-port-start.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

same "low ports protected" '{"id":"unprivileged-port-start","ok":true,"value":"1024 or higher","raw":"ip_unprivileged_port_start = 1024"}' \
  "$(bash "$here/unprivileged-port-start.sh" /dev/stdin <<<1024)"
same "a higher threshold has the same value" '{"id":"unprivileged-port-start","ok":true,"value":"1024 or higher","raw":"ip_unprivileged_port_start = 2048"}' \
  "$(bash "$here/unprivileged-port-start.sh" /dev/stdin <<<2048)"
same "every port open" false "$(bash "$here/unprivileged-port-start.sh" /dev/stdin <<<0 | jq .ok)"
same "below boundary" '{"id":"unprivileged-port-start","ok":false,"value":"1023","raw":"ip_unprivileged_port_start = 1023"}' \
  "$(bash "$here/unprivileged-port-start.sh" /dev/stdin <<<1023)"
status=0
output=$(bash "$here/unprivileged-port-start.sh" /dev/stdin <<<invalid 2>/dev/null) || status=$?
same_text "invalid value exits 2" 2 "$status"
same_text "invalid value has no output" '' "$output"

finish
