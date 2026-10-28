#!/usr/bin/env bash
# Checks the low-port threshold and file capabilities under /usr and /opt.
# Usage: low-ports.sh [SYSCTL_FILE]
# Exit: 0 with one JSON check, 2 for an invalid threshold; nonzero on errors.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"

threshold=$(< "${1:-/proc/sys/net/ipv4/ip_unprivileged_port_start}")
[[ $threshold =~ ^[0-9]+$ ]] || die "invalid ip_unprivileged_port_start: $threshold"
failures=()
details=("ip_unprivileged_port_start = $threshold")
((threshold >= 1024)) || failures+=("ip_unprivileged_port_start = $threshold")
if have getcap; then
  capabilities=$(getcap -r /usr /opt)
  hits=$(awk '/(^|[[:space:],])cap_net_bind_service([=,+[:space:]]|$)/' <<<"$capabilities")
  if [[ -n $hits ]]; then
    failures+=("${hits//$'\n'/; }")
    details+=("${hits//$'\n'/; }")
  else
    details+=("no cap_net_bind_service under /usr or /opt")
  fi
else
  failures+=("getcap not found")
  details+=("getcap not found")
fi
ok=true value=none
if ((${#failures[@]})); then
  ok=false value=$(joined "${failures[@]}")
fi
add_check low-ports "$ok" "$value" "$(joined "${details[@]}")"
