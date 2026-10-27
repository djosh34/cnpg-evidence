#!/usr/bin/env bash
# Checks pod object-id separators and missing-process errors with process fixtures.
# Usage: bash postmaster.test.sh
# Exit: 0 all assertions pass, 1 an assertion fails, nonzero on a test error.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

pgrep() { printf '%s\n' 123 456; }
grep() { [[ $* == '-Eq podtest[-_]pod /proc/456/cgroup' && ${missing:-} != true ]]; }
export -f pgrep grep
actual=$(bash "$here/postmaster.sh" test-pod)
same_text 'cgroup pod uid with either separator' 456 "$actual"
status=0
actual=$(missing=true bash "$here/postmaster.sh" test-pod) || status=$?
same_text 'missing process exit' 2 "$status"
same_text 'missing process output' '' "$actual"
finish
