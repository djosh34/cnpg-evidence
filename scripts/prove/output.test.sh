#!/usr/bin/env bash
# Checks target identity, record fields and probe order in the combined output.
# Usage: bash output.test.sh
# Exit: 0 all assertions pass, 1 an assertion fails, nonzero on a test error.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../lib/test.sh"

actual=$(jq -s --arg node node1 --arg namespace databases --arg cluster pg -f "$here/output.jq" <<'JSON'
{"probe":"one","expected":"denied","actual":"denied","ok":true}
{"probe":"two","expected":"connected","actual":"connected","ok":true}
JSON
)
expected=$(cat <<'JSON'
{"node":"node1","namespace":"databases","cluster":"pg","probes":[
{"probe":"one","expected":"denied","actual":"denied","ok":true},
{"probe":"two","expected":"connected","actual":"connected","ok":true}]}
JSON
)
same 'output preserves probe order and fields' "$expected" "$actual"
finish
