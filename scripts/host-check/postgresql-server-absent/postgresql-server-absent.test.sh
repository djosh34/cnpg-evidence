#!/usr/bin/env bash
# Tests PostgreSQL server package detection and missing rpm.
# Usage: bash postgresql-server-absent.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

rpm() { echo 'postgresql-server-18'; }
export -f rpm
same "server package" '{"id":"postgresql-server-absent","ok":false,"value":"postgresql-server-18","raw":"installed: postgresql-server-18"}' "$(bash "$here/postgresql-server-absent.sh")"
rpm() { :; }
export -f rpm
same "no server package" '{"id":"postgresql-server-absent","ok":true,"value":"none","raw":"no postgresql*-server package installed"}' "$(bash "$here/postgresql-server-absent.sh")"
command() {
  [[ $* != '-v rpm' ]] || return 1
  builtin command "$@"
}
export -f command
same "missing rpm" '{"id":"postgresql-server-absent","ok":false,"value":"rpm not found","raw":"rpm not found"}' "$(bash "$here/postgresql-server-absent.sh")"

finish
