#!/usr/bin/env bash
# Tests argument and collection error exit codes and stdout.
# Usage: bash host-check.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib/test.sh"

status=0
output=$(bash "$here/host-check.sh" --invalid 26 2>/dev/null) || status=$?
same_text "bad option exit" 2 "$status"
same_text "bad option stdout" '' "$output"
status=0
output=$(bash "$here/host-check.sh" --postgres-uid nope 2>/dev/null) || status=$?
same_text "bad uid exit" 2 "$status"
same_text "bad uid stdout" '' "$output"
status=0
output=$(bash "$here/host-check.sh" --storage-dir 2>/dev/null) || status=$?
same_text "missing value exit" 2 "$status"
same_text "missing value stdout" '' "$output"

bash() { echo partial; return 1; }
export -f bash
status=0
output=$(/bin/bash "$here/host-check.sh" 2>/dev/null) || status=$?
same_text "collection error or non-root exits 2" 2 "$status"
same_text "collection error has no stdout" '' "$output"

finish
