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
    'get pv pv-test -o json') echo "{\"spec\":{\"local\":{\"path\":\"$data_dir\"}}}" ;;
    *) return 2 ;;
  esac
}
pgrep() { echo "$test_pid"; }
grep() { [[ ${no_process:-} != true ]]; }
setpriv() { echo 'Permission denied' >&2; return 2; }
export -f kubectl pgrep grep setpriv
export test_pid=$$
# The data directory exists, the socket paths do not.
data_dir=$(mktemp -d)
trap 'rm -rf "$data_dir"' EXIT
mkdir "$data_dir/pgdata"
touch "$data_dir/pgdata/PG_VERSION"
export data_dir
# desired_rows RECORDS: the rows of the desired prove document, from
# scripts/desired, for the probes in RECORDS, sorted by name.
desired_rows() {
  jq -n '{cluster: {name: "pg", namespace: "databases", instances: 3}, caSecret: "client-ca",
          rwLoadBalancer: {name: "pg-rw-lb"}, network: {operatorNamespace: "cnpg-system"},
          replication: {commonName: "pg-replication"}, databases: [{name: "orders", role: "orders", clientCNs: []}]}' |
    bash "$here/../../desired/desired.sh" --source prove |
    jq -c --argjson records "$1" '[.probes[] | select(.probe as $name | any($records[]; .probe == $name))] | sort_by(.probe)'
}
result=$(bash "$here/uid.sh" databases pg node1 '' 26 | jq -s .)
same_text 'three uid paths' 3 "$(jq length <<<"$result")"
same_text 'missing root paths cannot prove denial' 2 "$(jq '[.[] | select(.ok == false and .value == "error" and (.actual | contains("missing as root")))] | length' <<<"$result")"
same 'existing data denial' '{"probe":"uid-26 pgdata-host-path","target":"pg-test","value":"denied","ok":true}' \
  "$(jq -c '.[1] | {probe, target, value, ok}' <<<"$result")"
same 'the mapped uid is in the target, not the name' '{"probe":"uid-mapped socket-host-path","target":"pg-test uid 26"}' \
  "$(jq -c '.[2] | {probe, target}' <<<"$result")"
same_text 'the expected text names no path' 'Permission denied' "$(jq -r 'map(.expected) | unique | join(", ")' <<<"$result")"
same 'names and texts as in the desired document' "$(desired_rows "$result" | jq -c 'map({probe, expected})')" \
  "$(jq -c 'map({probe, expected}) | sort_by(.probe)' <<<"$result")"
result=$(no_pods=true bash "$here/uid.sh" databases pg node1 '' 26 | jq -s .)
same 'no local pods fail' '{"probe":"uid-probes","target":"node1","value":"not found","ok":false}' \
  "$(jq -c '.[0] | {probe, target, value, ok}' <<<"$result")"
result=$(no_process=true bash "$here/uid.sh" databases pg node1 '' 26 | jq -s .)
same_text 'no postmaster fails' 'not found' "$(jq -r '.[0].value' <<<"$result")"
# Both socket commands pass the helper text as the bash -c argument.
# shellcheck disable=SC2016
same_text 'the mapped socket probe passes the root-read helper text' 1 \
  "$(command grep -Fc 'bash -c "$socket_text" socket.sh "$socket_dir"' "$here/uid.sh")"
# shellcheck disable=SC2016
same_text 'helper is read before dropping uid' 'socket_text=$(<"$here/socket.sh")' \
  "$(command grep -F 'socket_text=' "$here/uid.sh")"
finish
