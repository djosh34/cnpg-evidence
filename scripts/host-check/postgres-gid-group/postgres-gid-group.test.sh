#!/usr/bin/env bash
# Tests supplementary member account checks and NSS query errors.
# Usage: bash postgres-gid-group.test.sh
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
same "locked supplementary group member" '{"id":"postgres-gid-group","ok":true,"value":"none","raw":"group postgres gid=26 members=postgres; member postgres uid=26 gid=26 shell=/sbin/nologin locked=yes"}' "$(bash "$here/postgres-gid-group.sh" 26 26)"
getent() {
  case $* in
    'passwd') echo 'root:x:0:0:root:/root:/bin/bash' ;;
    'passwd postgres') echo 'postgres:x:26:26::/:/sbin/nologin' ;;
    'passwd alice') echo 'alice:x:1000:1000::/:/bin/bash' ;;
    'group'|'group 26') echo 'postgres:x:26:postgres,alice' ;;
    'shadow postgres') echo 'postgres:!:1:0:99999:7:::' ;;
    'shadow alice') echo 'alice:password-hash:1:0:99999:7:::' ;;
    *) return 2 ;;
  esac
}
export -f getent
same_text "an open member is the value" alice "$(bash "$here/postgres-gid-group.sh" 26 26 | jq -r .value)"

getent() { return 1; }
export -f getent
status=0
output=$(bash "$here/postgres-gid-group.sh" 26 26) || status=$?
same_text "enumeration failure exits 2" 2 "$status"
same_text "enumeration failure stdout" '' "$output"

finish
