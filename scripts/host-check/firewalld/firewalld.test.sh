#!/usr/bin/env bash
# Tests running, stopped and absent firewalld collection as distinct facts.
# Usage: bash firewalld.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

firewall-cmd() {
  case $* in
    --state) echo running ;;
    --get-active-zones) printf 'public\n  interfaces: eth0\n' ;;
    *--get-target) echo default ;;
    *--list-interfaces) echo eth0 ;;
    *--list-sources) echo '' ;;
    *--list-services) echo ssh ;;
    *--list-ports) echo 443/tcp ;;
    *--list-rich-rules) echo 'rule one' ;;
    *) return 9 ;;
  esac
}
export -f firewall-cmd
expected=$(cat <<'JSON'
{"state":"running","zones":[{"zone":"public","target":"default","interfaces":["eth0"],"sources":[],"services":["ssh"],"ports":["443/tcp"],"rich_rules":["rule one"]}]}
JSON
)
same "running zones" "$expected" "$(bash "$here/firewalld.sh")"
firewall-cmd() { echo 'not running'; return 252; }
export -f firewall-cmd
same "stopped" '{"state":"not running","zones":[]}' "$(bash "$here/firewalld.sh")"
command() {
  [[ $* != '-v firewall-cmd' ]] || return 1
  builtin command "$@"
}
export -f command
same "missing" null "$(bash "$here/firewalld.sh")"

finish
