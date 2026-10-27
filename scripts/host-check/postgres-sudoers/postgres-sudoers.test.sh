#!/usr/bin/env bash
# Tests real sudoers matching on explicit files, independent of host sudo policy.
# Usage: bash postgres-sudoers.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

getent() {
  case $* in
    passwd) echo 'root:x:0:0:root:/root:/bin/bash' ;;
    'passwd 26'|'passwd postgres') echo 'postgres:x:26:26::/:/sbin/nologin' ;;
    group|'group 26') echo 'postgres:x:26:postgres' ;;
    *) return 2 ;;
  esac
}
export -f getent

actual=$(bash "$here/postgres-sudoers.sh" 26 26 <(cat <<'SUDOERS'
example ALL=(postgres) ALL
SUDOERS
))
same "named sudoers line fails" false "$(jq .ok <<<"$actual")"
same_text "matching line reported with location" true \
  "$(jq '.value | endswith(":1: example ALL=(postgres) ALL")' <<<"$actual")"

actual=$(bash "$here/postgres-sudoers.sh" 26 26 <(cat <<'SUDOERS'
#26 ALL=(ALL) ALL
SUDOERS
))
same "numeric uid is not a comment" false "$(jq .ok <<<"$actual")"
same_text "numeric uid line reported" true \
  "$(jq '.value | endswith(":1: #26 ALL=(ALL) ALL")' <<<"$actual")"

actual=$(bash "$here/postgres-sudoers.sh" 26 26 <(cat <<'SUDOERS'
# postgres ALL=(ALL) ALL
  # example ALL=(postgres) ALL
#
SUDOERS
))
same "commented names ignored" true "$(jq .ok <<<"$actual")"

actual=$(bash "$here/postgres-sudoers.sh" 26 26 <(cat <<'SUDOERS'
root ALL=(ALL) ALL
postgresql ALL=(ALL) ALL
#260 ALL=(ALL) ALL
SUDOERS
))
same "non-matching names ignored" true "$(jq .ok <<<"$actual")"

actual=$(bash "$here/postgres-sudoers.sh" 26 26 <(cat <<'SUDOERS'
root ALL=(ALL) ALL
SUDOERS
) <(cat <<'SUDOERS'
postgres ALL=(ALL) ALL
SUDOERS
))
same "all explicit files searched" false "$(jq .ok <<<"$actual")"

getent() { return 1; }
export -f getent
status=0
output=$(bash "$here/postgres-sudoers.sh" 26 26 /dev/null) || status=$?
same_text "passwd enumeration failure exits 2" 2 "$status"
same_text "passwd enumeration failure stdout" '' "$output"
getent() {
  if [[ $1 == group ]]; then return 1; fi
  return 0
}
export -f getent
status=0
output=$(bash "$here/postgres-sudoers.sh" 26 26 /dev/null) || status=$?
same_text "group enumeration failure exits 2" 2 "$status"
same_text "group enumeration failure stdout" '' "$output"

finish
