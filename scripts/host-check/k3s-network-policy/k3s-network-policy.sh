#!/usr/bin/env bash
# Checks collected k3s flags for any network-policy disable setting.
# Usage: k3s-network-policy.sh <collected.json
# Exit: 0 with one JSON check (including a failed check), nonzero on errors.
set -euo pipefail
shopt -s inherit_errexit nullglob

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"

lines=$(jq -r '[.k3s_config[][] | select(test("disable-network-policy"))] | join("; ")')

if [[ -z $lines ]]; then
  add_check k3s-network-policy true none "no disable-network-policy flag"
else
  add_check k3s-network-policy false "$lines" "$lines"
fi
