#!/usr/bin/env bash
# Runs host checks in order, stopping on collection errors, not failed checks.
# Usage: checks.sh UID GID STORAGE_DIR <collected.json
# Exit: 0 with JSON checks, 2 on NSS errors; other nonzero exits are child errors.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

facts=$(< /dev/stdin)
bash "$here/../selinux/selinux.sh" <<<"$facts"
bash "$here/../postgres-account/postgres-account.sh" "$1" "$2"
bash "$here/../dir-modes/dir-modes.sh" "$3"
bash "$here/../k3s-secrets/k3s-secrets.sh"
bash "$here/../low-ports/low-ports.sh"
bash "$here/../k3s-network-policy/k3s-network-policy.sh"
