#!/usr/bin/env bash
# Tests the storage parent path and mode ceiling.
# Usage: bash storage-dir-mode.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

stat() { echo '700 root:root'; }
ls() { echo 'drwx------ 1 root root'; }
export -f stat ls
actual=$(bash "$here/storage-dir-mode.sh" /usr)
if [[ -e /usr ]]; then
  expected='{"id":"storage-dir-mode","ok":true,"detail":"/usr 700 root:root, want 700 or tighter, root:root, no ACL"}'
else
  expected='{"id":"storage-dir-mode","ok":false,"detail":"/usr missing"}'
fi
same "check path and ceiling" "$expected" "$actual"

finish
