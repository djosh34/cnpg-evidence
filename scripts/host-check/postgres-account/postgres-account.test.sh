#!/usr/bin/env bash
# Tests required account states and listed-only groups, sudoers and packages.
# Usage: bash postgres-account.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

getent() {
  case $* in
    passwd) echo 'other:x:99:99::/:/bin/bash' ;;
    'passwd 26'|'passwd postgres') echo 'postgres:x:26:26::/:/sbin/nologin' ;;
    group|'group 26') echo 'postgres:x:26:other' ;;
    'shadow postgres') echo 'postgres:!:1:0:99999:7:::' ;;
    *) return 2 ;;
  esac
}
rpm() { echo postgresql16-server; }
bash() { echo '{"ok":false,"raw":"/etc/sudoers:1: postgres ALL=(ALL) ALL"}'; }
export -f getent rpm bash
actual=$(/bin/bash "$here/postgres-account.sh" 26 26)
same "locked direct uid account" '{"id":"postgres-account","ok":true,"value":"none"}' "$(jq '{id,ok,value}' <<<"$actual")"
same "group, sudoers and rpm are only listed" true "$(jq '.raw | contains("members=other") and contains("postgres ALL=(ALL) ALL") and contains("postgresql16-server")' <<<"$actual")"
getent() {
  case $1 in
    passwd) echo 'postgres:x:26:26::/:/bin/bash' ;;
    shadow) echo 'postgres:!:1:0:99999:7:::' ;;
    group) echo 'postgres:x:26:' ;;
  esac
}
export -f getent
same "login shell fails" '{"ok":false,"value":"not locked with nologin: postgres"}' \
  "$(/bin/bash "$here/postgres-account.sh" 26 26 | jq '{ok,value}')"
getent() {
  case $* in
    passwd) echo 'primary:x:99:26::/:/sbin/nologin' ;;
    'passwd primary') echo 'primary:x:99:26::/:/sbin/nologin' ;;
    'shadow primary') echo 'primary:password:1:0:99999:7:::' ;;
    group) echo 'root:x:0:' ;;
    *) return 2 ;;
  esac
}
export -f getent
same_text "unlocked primary gid account fails" 'not locked with nologin: primary' \
  "$(/bin/bash "$here/postgres-account.sh" 26 26 | jq -r .value)"
getent() {
  case $* in
    passwd) echo 'root:x:0:0:root:/root:/bin/bash' ;;
    group) echo 'root:x:0:' ;;
    *) return 2 ;;
  esac
}
command() {
  if [[ $* == '-v rpm' ]]; then return 1; fi
  builtin command "$@"
}
export -f getent command
actual=$(/bin/bash "$here/postgres-account.sh" 26 26)
same "no account and missing rpm pass" '{"ok":true,"value":"none"}' "$(jq '{ok,value}' <<<"$actual")"
same "missing rpm is listed" true "$(jq '.raw | contains("rpm not found")' <<<"$actual")"
command() {
  if [[ $* == '-v getent' ]]; then return 1; fi
  builtin command "$@"
}
export -f command
same_text "missing required getent fails" 'getent not found' "$(/bin/bash "$here/postgres-account.sh" 26 26 | jq -r .value)"
unset -f command
getent() { return 1; }
export -f getent
status=0
output=$(/bin/bash "$here/postgres-account.sh" 26 26) || status=$?
same_text "enumeration failure exits 2" 2 "$status"
same_text "enumeration failure stdout" '' "$output"

finish
