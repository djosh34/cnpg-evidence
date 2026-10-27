#!/usr/bin/env bash
# Checks the k3s kubeconfig's mode, root ownership and ACL marker.
# Usage: k3s-kubeconfig-mode.sh
# Exit: 0 with one JSON check (including a failed check), nonzero on errors.
set -euo pipefail
shopt -s inherit_errexit nullglob

here=$(dirname "${BASH_SOURCE[0]}")

exec bash "$here/../mode/mode.sh" k3s-kubeconfig-mode "/etc/rancher/k3s/k3s.yaml" 600
