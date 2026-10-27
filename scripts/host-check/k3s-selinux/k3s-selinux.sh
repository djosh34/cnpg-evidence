#!/usr/bin/env bash
# Checks containerd's enable_selinux setting and reports related k3s flags.
# Usage: k3s-selinux.sh <collected.json
# Exit: 0 with one JSON check (including a failed check), nonzero on errors.
set -euo pipefail
shopt -s inherit_errexit nullglob

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"

facts=$(< /dev/stdin)
enabled=$(jq -r '.containerd_enable_selinux // ""' <<<"$facts")
lines=$(jq -r '[.k3s_config[][] | select(test("selinux"))] | join("; ")' <<<"$facts")
ok=false
[[ $enabled != true ]] || ok=true

add_check k3s-selinux "$ok" \
  "enable_selinux = ${enabled:-unset} in the k3s containerd config; config: ${lines:-no selinux setting}"
