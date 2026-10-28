#!/usr/bin/env bash
# Reads k3s settings and checks for any network-policy disable setting.
# Usage: k3s-network-policy.sh [CONFIG_YAML [SYSTEMD_UNIT...]]
# Exit: 0 with one JSON check (including a failed check), nonzero on errors.
set -euo pipefail
shopt -s inherit_errexit nullglob

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"

settings=$(bash "$here/../k3s-config/k3s-config.sh" "$@")
lines=$(jq -r '[.[][] | select(test("disable-network-policy"))] | join("; ")' <<<"$settings")

if [[ -z $lines ]]; then
  add_check k3s-network-policy true none "no disable-network-policy flag"
else
  add_check k3s-network-policy false "$lines" "$lines"
fi
