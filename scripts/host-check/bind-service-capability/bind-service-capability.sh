#!/usr/bin/env bash
# Finds cap_net_bind_service on files under /usr and /opt.
# Usage: bind-service-capability.sh
# Exit: 0 with one JSON check (including a failed check), nonzero on errors.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"

if ! have getcap; then
  add_check bind-service-capability false "getcap not found" "getcap not found"
  exit 0
fi

capabilities=$(getcap -r /usr /opt)
hits=$(awk '/(^|[[:space:],])cap_net_bind_service([=,+[:space:]]|$)/' <<<"$capabilities")

if [[ -z $hits ]]; then
  add_check bind-service-capability true none "no cap_net_bind_service under /usr or /opt"
else
  add_check bind-service-capability false "${hits//$'\n'/; }" "${hits//$'\n'/; }"
fi
