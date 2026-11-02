#!/usr/bin/env bash
# Checks that k3s's network policy controller runs on this node: in the
# iptables filter table, INPUT, FORWARD and OUTPUT jump to its chains
# KUBE-ROUTER-INPUT, KUBE-ROUTER-FORWARD and KUBE-ROUTER-OUTPUT. k3s leaves
# the controller off for its disable-network-policy setting, and also by
# itself, with only a log line, when ipset is missing; the chains show both.
# Usage: k3s-network-policy.sh
# Exit: 0 with one JSON check (including a failed check), nonzero on errors.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"

# k3s uses the host's iptables, or its own when the host has none.
bundled=/var/lib/rancher/k3s/data/current/bin/aux/iptables-save
if have iptables-save; then
  rules=$(iptables-save -t filter)
elif [[ -x $bundled ]]; then
  rules=$("$bundled" -t filter)
else
  add_check k3s-network-policy false "iptables-save not found" "iptables-save not found"
  exit 0
fi

jumps=$(awk '$1 == "-A" && $(NF - 1) == "-j" && $NF == "KUBE-ROUTER-" $2 {print $NF}' <<<"$rules")
missing=()
for chain in INPUT FORWARD OUTPUT; do
  grep -qx "KUBE-ROUTER-$chain" <<<"$jumps" || missing+=("KUBE-ROUTER-$chain")
done
found=()
[[ -z $jumps ]] || mapfile -t found <<<"$jumps"

if ((${#missing[@]})); then
  add_check k3s-network-policy false "$(listed "no jump to" "${missing[@]}")" "$(listed "jumps to" "${found[@]}")"
else
  add_check k3s-network-policy true none "$(listed "jumps to" "${found[@]}")"
fi
