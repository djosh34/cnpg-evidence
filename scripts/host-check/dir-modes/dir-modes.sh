#!/usr/bin/env bash
# Checks the storage and kubelet pod directories' modes, ownership and ACLs.
# Usage: dir-modes.sh [STORAGE_DIR [PODS_DIR]]
# Exit: 0 with one JSON check, nonzero on collection errors.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"

paths=("${1:-/var/lib/rancher/k3s/storage}" "${2:-/var/lib/kubelet/pods}")
limits=(700 750)
failures=()
details=()
for i in 0 1; do
  check=$(bash "$here/../mode/mode.sh" dir-modes "${paths[i]}" "${limits[i]}")
  details+=("$(jq -r .raw <<<"$check")")
  if [[ $(jq -r .ok <<<"$check") == false ]]; then
    failures+=("${paths[i]}: $(jq -r .value <<<"$check")")
  fi
done
ok=true value=none
if ((${#failures[@]})); then
  ok=false value=$(joined "${failures[@]}")
fi
add_check dir-modes "$ok" "$value" "$(joined "${details[@]}")"
