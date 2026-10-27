#!/usr/bin/env bash
# Tests ss collection and missing-tool output.
# Usage: bash listening-tcp.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

ss() {
  [[ $* == -Htlnp ]] || return 9
  echo 'LISTEN 0 128 127.0.0.1:25 0.0.0.0:*'
}
export -f ss
same "ss collection" '[{"address":"127.0.0.1","port":25,"processes":[]}]' "$(bash "$here/listening-tcp.sh")"
command() {
  [[ $* != '-v ss' ]] || return 1
  builtin command "$@"
}
export -f command
same "no ss" null "$(bash "$here/listening-tcp.sh")"

finish
