#!/usr/bin/env bash
# Tests the low-port threshold and invalid input.
# Usage: bash unprivileged-port-start.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

same "low ports protected" '{"id":"unprivileged-port-start","ok":true,"detail":"ip_unprivileged_port_start = 1024, want 1024 or higher"}' \
  "$(bash "$here/unprivileged-port-start.sh" /dev/stdin <<<1024)"
same "higher boundary" true "$(bash "$here/unprivileged-port-start.sh" /dev/stdin <<<2048 | jq .ok)"
same "every port open" false "$(bash "$here/unprivileged-port-start.sh" /dev/stdin <<<0 | jq .ok)"
same "below boundary" false "$(bash "$here/unprivileged-port-start.sh" /dev/stdin <<<1023 | jq .ok)"
status=0
output=$(bash "$here/unprivileged-port-start.sh" /dev/stdin <<<invalid 2>/dev/null) || status=$?
same_text "invalid value exits 2" 2 "$status"
same_text "invalid value has no output" '' "$output"

finish
