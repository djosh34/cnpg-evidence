#!/usr/bin/env bash
# Tests shared text joining and JSON-check output.
# Usage: bash lib.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib/test.sh"

actual=$(bash -c 'source "$1/lib.sh"; joined first second' bash "$here")
same_text "join details" 'first; second' "$actual"
actual=$(bash -c 'source "$1/lib.sh"; listed first second' bash "$here")
same_text "list texts" 'first; second' "$actual"
actual=$(bash -c 'source "$1/lib.sh"; listed' bash "$here")
same_text "an empty list is none" none "$actual"
actual=$(bash -c 'source "$1/lib.sh"; add_check example false open "what was read"' bash "$here")
same "check JSON" '{"id":"example","ok":false,"value":"open","raw":"what was read"}' "$actual"

finish
