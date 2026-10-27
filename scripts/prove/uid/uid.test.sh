#!/usr/bin/env bash
# Checks missing paths, process lookup and socket-helper arguments using command fixtures.
# Usage: bash uid.test.sh
# Exit: 0 all assertions pass, 1 an assertion fails, nonzero on a test error.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

kubectl() {
  case $* in
    *'pods -l '*)
      if [[ ${no_pods:-} == true ]]; then
        echo '{"items":[]}'
      else
        cat <<'JSON'
{"items":[{"metadata":{"name":"pg-test","uid":"missing-pod"}}]}
JSON
      fi
      ;;
    *'pvc pg-test'*) echo '{"spec":{"volumeName":"pv-test"}}' ;;
    'get pv pv-test -o json') echo '{"spec":{"local":{"path":"/missing-prove-data"}}}' ;;
    *) return 2 ;;
  esac
}
pgrep() { echo "$test_pid"; }
grep() { [[ ${no_process:-} != true ]]; }
setpriv() { echo 'Permission denied' >&2; return 2; }
export -f kubectl pgrep grep setpriv
export test_pid=$$
result=$(bash "$here/uid.sh" databases pg node1 '' 26 | jq -s .)
same_text 'seven uid paths' 7 "$(jq length <<<"$result")"
same_text 'missing root paths cannot prove denial' 6 "$(jq '[.[] | select(.ok == false and .value == "error" and (.actual | contains("missing as root")))] | length' <<<"$result")"
same 'existing environ denial' '{"probe":"uid-26 environ","target":"pg-test","value":"denied","ok":true}' \
  "$(jq -c '.[2] | {probe, target, value, ok}' <<<"$result")"
same 'the mapped uid is in the target, not the name' '{"probe":"uid-mapped socket-host-path","target":"pg-test uid 26"}' \
  "$(jq -c '.[6] | {probe, target}' <<<"$result")"
same_text 'the expected text names no path' 'Permission denied' "$(jq -r 'map(.expected) | unique | join(", ")' <<<"$result")"
result=$(no_pods=true bash "$here/uid.sh" databases pg node1 '' 26 | jq -s .)
same 'no local pods fail' '{"probe":"uid-probes","target":"node1","value":"not found","ok":false}' \
  "$(jq -c '.[0] | {probe, target, value, ok}' <<<"$result")"
result=$(no_process=true bash "$here/uid.sh" databases pg node1 '' 26 | jq -s .)
same_text 'no postmaster fails' 'not found' "$(jq -r '.[0].value' <<<"$result")"
# Both socket commands pass the helper text as the bash -c argument.
# shellcheck disable=SC2016
same_text 'both socket probes pass the root-read helper text' 2 \
  "$(command grep -Fc 'bash -c "$socket_text" socket.sh "$socket_dir"' "$here/uid.sh")"
# shellcheck disable=SC2016
same_text 'helper is read before dropping uid' 'socket_text=$(<"$here/socket.sh")' \
  "$(command grep -F 'socket_text=' "$here/uid.sh")"
finish
