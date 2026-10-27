#!/usr/bin/env bash
# Tests direct account checks and NSS query errors.
# Usage: bash postgres-uid-account.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

getent() {
  case $* in
    'passwd') echo 'root:x:0:0:root:/root:/bin/bash' ;;
    'passwd 26'|'passwd postgres') echo 'postgres:x:26:26::/:/sbin/nologin' ;;
    'group'|'group 26') echo 'postgres:x:26:postgres' ;;
    'shadow postgres') echo 'postgres:!:1:0:99999:7:::' ;;
    *) return 2 ;;
  esac
}
export -f getent
same "locked direct uid account" '{"id":"postgres-uid-account","ok":true,"value":"none","raw":"postgres uid=26 gid=26 shell=/sbin/nologin locked=yes"}' "$(bash "$here/postgres-uid-account.sh" 26 26)"
getent() {
  case $1 in
    passwd) echo 'postgres:x:26:26::/:/bin/bash' ;;
    shadow) echo 'postgres:!:1:0:99999:7:::' ;;
  esac
}
export -f getent
same "login shell fails" '{"id":"postgres-uid-account","ok":false,"value":"not locked with nologin: postgres","raw":"postgres uid=26 gid=26 shell=/bin/bash locked=yes"}' \
  "$(bash "$here/postgres-uid-account.sh" 26 26)"
getent() {
  case $* in
    passwd) echo 'root:x:0:0:root:/root:/bin/bash' ;;
    *) return 2 ;;
  esac
}
export -f getent
same "no account has the same value as a locked one" '{"id":"postgres-uid-account","ok":true,"value":"none","raw":"no account with uid 26 or primary gid 26"}' \
  "$(bash "$here/postgres-uid-account.sh" 26 26)"
getent() {
  case $1 in
    passwd) echo 'none:x:26:26::/:/bin/bash' ;;
    shadow) echo 'none:!:1:0:99999:7:::' ;;
  esac
}
export -f getent
same "an open account named none differs from no account" \
  '{"ok":false,"value":"not locked with nologin: none"}' \
  "$(bash "$here/postgres-uid-account.sh" 26 26 | jq -c '{ok, value}')"

getent() { return 1; }
export -f getent
status=0
output=$(bash "$here/postgres-uid-account.sh" 26 26) || status=$?
same_text "enumeration failure exits 2" 2 "$status"
same_text "enumeration failure stdout" '' "$output"

finish
