#!/usr/bin/env bash
# Tests NSS account lookup, enumeration and query error handling.
# Usage: bash accounts.test.sh
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
actual=$(bash -c '
  source "$1/accounts.sh"
  postgres_accounts 26 26
  postgres_groups 26
  account_state postgres
' bash "$here")
expected=$(cat <<'TEXT'
postgres
postgres:26:postgres
postgres uid=26 gid=26 shell=/sbin/nologin locked=yes
TEXT
)
same_text "NSS account helpers" "$expected" "$actual"

getent() {
  case $* in
    passwd) echo 'root:x:0:0:root:/root:/bin/bash' ;;
    group) echo 'root:x:0:' ;;
    *) return 2 ;;
  esac
}
export -f getent
actual=$(bash -c '
  source "$1/accounts.sh"
  postgres_accounts 26 26
  postgres_groups 26
' bash "$here")
same_text "missing direct keys are allowed" '' "$actual"

for database in passwd group; do
  for failure in 1 2; do
    getent() {
      if [[ $1 == "$database" && $# == 1 ]]; then return "$failure"; fi
      return 2
    }
    export -f getent
    export database failure
    status=0
    output=$(bash -c '
      source "$1/accounts.sh"
      if [[ $database == passwd ]]; then postgres_accounts 26 26; else postgres_groups 26; fi
    ' bash "$here") || status=$?
    same_text "$database enumeration exit $failure is an error" 2 "$status"
    same_text "$database enumeration error stdout" '' "$output"
  done
done

getent() {
  if (($# == 1)); then return 0; fi
  return 1
}
export -f getent
for helper in postgres_accounts postgres_groups; do
  status=0
  output=$(bash -c '
    source "$1/accounts.sh"
    "$2" 26 26
  ' bash "$here" "$helper") || status=$?
  same_text "$helper direct lookup error" 2 "$status"
  same_text "$helper direct lookup error stdout" '' "$output"
done

finish
