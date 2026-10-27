#!/usr/bin/env bash
# Checks exit status and stdout after usage and collection failures.
# Usage: bash prove.test.sh
# Exit: 0 all assertions pass, 1 an assertion fails, nonzero on a test error.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../lib/test.sh"

for arguments in --unknown '--postgres-uid nope' --node-root; do
  status=0
  # shellcheck disable=SC2086
  actual=$(bash "$here/prove.sh" $arguments 2>/dev/null) || status=$?
  same_text "$arguments exit" 2 "$status"
  same_text "$arguments stdout" '' "$actual"
done

kubectl() { echo 'API denied' >&2; return 2; }
export -f kubectl
status=0
actual=$(bash "$here/prove.sh" 2>/dev/null) || status=$?
same_text 'child collection error exits 2' 2 "$status"
same_text 'collection error has no stdout' '' "$actual"
finish
