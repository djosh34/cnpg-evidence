#!/usr/bin/env bash
# Tests check dispatch and collection error propagation.
# Usage: bash checks.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

bash() {
  echo '{"id":"stub","ok":true,"value":"none","raw":"fixture"}'
}
export -f bash
actual=$(/bin/bash "$here/checks.sh" 26 26 /storage <<<'{}' | jq -s 'length')
same_text "all checks invoked" 13 "$actual"
bash() { return 7; }
export -f bash
status=0
output=$(/bin/bash "$here/checks.sh" 26 26 /storage <<<'{}') || status=$?
same_text "child failures stop collection" 7 "$status"
same_text "failed collection stdout" '' "$output"

unset -f bash
getent() { return 1; }
export -f getent
status=0
output=$(/bin/bash "$here/checks.sh" 26 26 /storage <<<'{}') || status=$?
same_text "account enumeration failure stops checks" 2 "$status"
same "only the preceding SELinux check was printed" '["selinux-enforcing"]' \
  "$(jq -s 'map(.id)' <<<"$output")"

finish
