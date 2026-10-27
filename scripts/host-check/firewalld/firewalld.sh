#!/usr/bin/env bash
# Collects firewalld state and active-zone settings.
# Usage: firewalld.sh
# Exit: 0 with JSON (null without firewall-cmd), nonzero on collection errors.
set -euo pipefail
shopt -s inherit_errexit nullglob

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"

if ! have firewall-cmd; then
  echo null
  exit 0
fi
state=$(firewall-cmd --state 2>&1) || true
if [[ $state != running ]]; then
  jq -n --arg state "$state" '{state: $state, zones: []}'
  exit 0
fi
zones=$(firewall-cmd --get-active-zones | awk '/^[^[:space:]]/ {print $1}')
for zone in $zones; do
  target=$(firewall-cmd --permanent --zone="$zone" --get-target)
  interfaces=$(firewall-cmd --zone="$zone" --list-interfaces)
  sources=$(firewall-cmd --zone="$zone" --list-sources)
  services=$(firewall-cmd --zone="$zone" --list-services)
  ports=$(firewall-cmd --zone="$zone" --list-ports)
  rich_rules=$(firewall-cmd --zone="$zone" --list-rich-rules)
  jq -n --arg zone "$zone" \
    --arg target "$target" --arg interfaces "$interfaces" \
    --arg sources "$sources" --arg services "$services" \
    --arg ports "$ports" --arg rich_rules "$rich_rules" \
    -f "$here/firewalld.jq"
done | jq -s '{state: "running", zones: .}'
