#!/usr/bin/env bash
# Tests kubelet's pod directory path and mode ceiling.
# Usage: bash kubelet-pods-mode.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

stat() { echo '750 root:root'; }
ls() { echo 'drwx------ 1 root root'; }
export -f stat ls
actual=$(bash "$here/kubelet-pods-mode.sh" /usr)
if [[ -e /var/lib/kubelet/pods ]]; then
  expected='{"id":"kubelet-pods-mode","ok":true,"value":"750 or tighter, root:root, no ACL","raw":"/var/lib/kubelet/pods 750 root:root"}'
else
  expected='{"id":"kubelet-pods-mode","ok":false,"value":"missing","raw":"/var/lib/kubelet/pods missing"}'
fi
same "check path and ceiling" "$expected" "$actual"

finish
