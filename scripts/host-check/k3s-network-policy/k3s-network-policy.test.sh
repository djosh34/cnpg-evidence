#!/usr/bin/env bash
# Tests the network policy controller check on the node's iptables rules,
# whatever the k3s settings say.
# Usage: bash k3s-network-policy.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

# The rules of a k3s node, shortened from iptables-save -t filter.
running=$(cat <<'RULES'
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:KUBE-ROUTER-FORWARD - [0:0]
:KUBE-ROUTER-INPUT - [0:0]
:KUBE-ROUTER-OUTPUT - [0:0]
-A INPUT -m comment --comment "kube-router netpol - 4IA2OSFRMVNDXBVV" -j KUBE-ROUTER-INPUT
-A INPUT -j KUBE-FIREWALL
-A FORWARD -m comment --comment "kube-router netpol - TEMCG2JMHZYE7H7T" -j KUBE-ROUTER-FORWARD
-A OUTPUT -m comment --comment "kube-router netpol - VEAAIY32XVBHCSCY" -j KUBE-ROUTER-OUTPUT
-A KUBE-ROUTER-FORWARD -j KUBE-POD-FW-6TQBBLHYWDFHOA3D
COMMIT
RULES
)
rules=$running
iptables-save() {
  [[ $* == '-t filter' ]] || return 2
  echo "$rules"
}
export rules
export -f iptables-save
same "the controller's chains pass" \
  '{"id":"k3s-network-policy","ok":true,"value":"none","raw":"jumps to: KUBE-ROUTER-INPUT; KUBE-ROUTER-FORWARD; KUBE-ROUTER-OUTPUT"}' \
  "$(bash "$here/k3s-network-policy.sh")"

# Without ipset, k3s starts no controller and no setting says so.
rules=$(grep -v KUBE-ROUTER <<<"$running")
same "no controller fails, with no setting that turns it off" \
  '{"id":"k3s-network-policy","ok":false,"value":"no jump to: KUBE-ROUTER-INPUT; KUBE-ROUTER-FORWARD; KUBE-ROUTER-OUTPUT","raw":"none"}' \
  "$(bash "$here/k3s-network-policy.sh")"
rules=$(grep -v -- '-A FORWARD' <<<"$running")
same_text "a missing jump fails" 'no jump to: KUBE-ROUTER-FORWARD' "$(bash "$here/k3s-network-policy.sh" | jq -r .value)"
# A chain of that name that nothing jumps to is no controller.
rules=$(grep -v -- '-j KUBE-ROUTER-' <<<"$running")
same_text "chains without jumps fail" 'no jump to: KUBE-ROUTER-INPUT; KUBE-ROUTER-FORWARD; KUBE-ROUTER-OUTPUT' \
  "$(bash "$here/k3s-network-policy.sh" | jq -r .value)"

iptables-save() { return 7; }
export -f iptables-save
status=0
output=$(bash "$here/k3s-network-policy.sh") || status=$?
same_text "an iptables-save error" 7 "$status"
same_text "error stdout" '' "$output"

command() {
  if [[ $* == '-v iptables-save' ]]; then return 1; fi
  builtin command "$@"
}
export -f command
same_text "missing iptables-save fails" 'iptables-save not found' "$(bash "$here/k3s-network-policy.sh" | jq -r .value)"

finish
