#!/usr/bin/env bash
# Checks /var/lib/kubelet/pods for its mode, root ownership and ACL marker.
# Usage: kubelet-pods-mode.sh
# Exit: 0 with one JSON check (including a failed check), nonzero on errors.
set -euo pipefail
shopt -s inherit_errexit nullglob

here=$(dirname "${BASH_SOURCE[0]}")

exec bash "$here/../mode/mode.sh" kubelet-pods-mode "/var/lib/kubelet/pods" 750
