#!/usr/bin/env bash
# Tests the kubeconfig path and mode ceiling.
# Usage: bash k3s-kubeconfig-mode.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

stat() { echo '600 root:root'; }
ls() { echo 'drwx------ 1 root root'; }
export -f stat ls
actual=$(bash "$here/k3s-kubeconfig-mode.sh" /usr)
if [[ -e /etc/rancher/k3s/k3s.yaml ]]; then
  expected='{"id":"k3s-kubeconfig-mode","ok":true,"detail":"/etc/rancher/k3s/k3s.yaml 600 root:root, want 600 or tighter, root:root, no ACL"}'
else
  expected='{"id":"k3s-kubeconfig-mode","ok":false,"detail":"/etc/rancher/k3s/k3s.yaml missing"}'
fi
same "check path and ceiling" "$expected" "$actual"

finish
