#!/usr/bin/env bash
# Checks whether the host unprivileged-port threshold is at least 1024.
# Usage: unprivileged-port-start.sh [SYSCTL_FILE]
# Exit: 0 with one JSON check, 2 for an invalid value; other nonzero exits
#   mean a command failed.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"

value=$(< "${1:-/proc/sys/net/ipv4/ip_unprivileged_port_start}")
[[ $value =~ ^[0-9]+$ ]] || die "invalid ip_unprivileged_port_start: $value"
ok=false
rule_value=$value
if ((value >= 1024)); then
  ok=true rule_value="1024 or higher"
fi

add_check unprivileged-port-start "$ok" "$rule_value" "ip_unprivileged_port_start = $value"
