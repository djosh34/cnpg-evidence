#!/usr/bin/env bash
# Checks the low-port threshold.
# Usage: low-ports.sh [SYSCTL_FILE]
# Exit: 0 with one JSON check, 2 for an invalid threshold; nonzero on errors.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"

threshold=$(< "${1:-/proc/sys/net/ipv4/ip_unprivileged_port_start}")
[[ $threshold =~ ^[0-9]+$ ]] || die "invalid ip_unprivileged_port_start: $threshold"
ok=true value=none
if ((threshold < 1024)); then
  ok=false value="ip_unprivileged_port_start = $threshold"
fi
add_check low-ports "$ok" "$value" "ip_unprivileged_port_start = $threshold"
