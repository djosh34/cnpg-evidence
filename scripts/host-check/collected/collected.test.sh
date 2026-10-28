#!/usr/bin/env bash
# Tests collection with missing optional tools.
# Usage: bash collected.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

command() {
  case $* in
    '-v ss'|'-v rpm'|'-v getent'|'-v k3s'|'-v getcap'|'-v containerd') return 1 ;;
    *) builtin command "$@" ;;
  esac
}
export -f command
actual=$(bash "$here/collected.sh" 26 27)
same "missing tools include getcap" '["ss","rpm","getent","k3s","getcap"]' "$(jq .missing_tools <<<"$actual")"
same "optional collected values" '{"k3s_version":null,"listening_tcp":null,"postgres_gid":27}' "$(jq '{k3s_version,listening_tcp,postgres_gid}' <<<"$actual")"

finish
