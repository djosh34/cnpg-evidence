#!/usr/bin/env bash
# Runs host checks in order, stopping on collection errors, not failed checks.
# Usage: checks.sh UID GID STORAGE_DIR <collected.json
# Exit: 0 with JSON checks, 2 on NSS errors; other nonzero exits are child errors.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

facts=$(< /dev/stdin)

bash "$here/../selinux-enforcing/selinux-enforcing.sh"
for check in postgres-uid-account postgres-gid-group postgres-sudoers; do
  bash "$here/../$check/$check.sh" "$1" "$2"
done
bash "$here/../postgresql-server-absent/postgresql-server-absent.sh"
bash "$here/../storage-dir-mode/storage-dir-mode.sh" "$3"
bash "$here/../kubelet-pods-mode/kubelet-pods-mode.sh"
bash "$here/../k3s-kubeconfig-mode/k3s-kubeconfig-mode.sh"
for check in k3s-selinux k3s-network-policy subordinate-ids \
  unprivileged-port-start bind-service-capability; do
  bash "$here/../$check/$check.sh" <<<"$facts"
done
