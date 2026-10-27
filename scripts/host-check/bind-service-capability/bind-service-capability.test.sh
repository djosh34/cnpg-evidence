#!/usr/bin/env bash
# Tests capability matching and missing-tool reporting.
# Usage: bash bind-service-capability.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

getcap() {
  [[ $* == '-r /usr /opt' ]] || return 9
  echo '/usr/bin/ping cap_net_raw=ep'
}
export -f getcap
same "unrelated capability" '{"id":"bind-service-capability","ok":true,"detail":"no cap_net_bind_service under /usr or /opt"}' "$(bash "$here/bind-service-capability.sh")"
getcap() {
  echo '/opt/server cap_net_raw,cap_net_bind_service=ep'
  echo '/usr/bin/server cap_net_bind_service,cap_net_raw=ep'
}
export -f getcap
same "file capabilities listed" '{"id":"bind-service-capability","ok":false,"detail":"/opt/server cap_net_raw,cap_net_bind_service=ep; /usr/bin/server cap_net_bind_service,cap_net_raw=ep"}' "$(bash "$here/bind-service-capability.sh")"
command() {
  [[ $* != '-v getcap' ]] || return 1
  builtin command "$@"
}
export -f command
same "missing getcap" '{"id":"bind-service-capability","ok":false,"detail":"getcap not found"}' "$(bash "$here/bind-service-capability.sh")"

finish
