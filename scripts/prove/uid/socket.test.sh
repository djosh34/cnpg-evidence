#!/usr/bin/env bash
# Checks cwd-based socket connections and exit status after failed traversal.
# Usage: bash socket.test.sh
# Exit: 0 all assertions pass, 1 an assertion fails, nonzero on a test error.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

psql() {
  [[ $PWD == / ]] || return 2
  printf '%s\n' "${!#}"
}
export -f psql
actual=$(bash "$here/socket.sh" /)
same_text 'socket uses cwd after traversal' 'host=/proc/self/cwd port=5432 dbname=postgres user=postgres' "$actual"
status=0
actual=$(bash "$here/socket.sh" /does-not-exist/prove-socket 2>/dev/null) || status=$?
same_text 'failed traversal exit' 2 "$status"
same_text 'failed traversal does not call psql' '' "$actual"
finish
