#!/usr/bin/env bash
# Checks the storage parent's mode, root ownership and ACL marker.
# Usage: storage-dir-mode.sh STORAGE_DIR
# Exit: 0 with one JSON check (including a failed check), nonzero on errors.
set -euo pipefail
shopt -s inherit_errexit nullglob

here=$(dirname "${BASH_SOURCE[0]}")

exec bash "$here/../mode/mode.sh" storage-dir-mode "$1" 700
