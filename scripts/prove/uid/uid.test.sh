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
# Logs the uid and gid of each attempt.
setpriv() {
  echo "$1 $2" >>"$setpriv_log"
  echo 'Permission denied' >&2
  return 2
}
export -f kubectl pgrep grep setpriv
export test_pid=$$
# The data directory exists, the socket paths do not.
data_dir=$(mktemp -d)
trap 'rm -rf "$data_dir"' EXIT
mkdir "$data_dir/pgdata"
touch "$data_dir/pgdata/PG_VERSION"
export data_dir
export setpriv_log=$data_dir/setpriv.log
# The test's own process stands for the postmaster, so its maps give the bases.
uid_base=$(awk '$1 == 0 {print $2}' "/proc/$$/uid_map")
gid_base=$(awk '$1 == 0 {print $2}' "/proc/$$/gid_map")
# desired_rows RECORDS: the rows of the desired prove document, from
# scripts/desired, for the probes in RECORDS, sorted by name.
desired_rows() {
  jq -n '{cluster: {name: "pg", namespace: "databases", instances: 3}, caSecret: "client-ca",
          rwLoadBalancer: {name: "pg-rw-lb"}, network: {operatorNamespace: "cnpg-system"},
          replication: {commonName: "pg-replication"}, databases: [{name: "orders", role: "orders", clientCNs: []}]}' |
    bash "$here/../../desired/desired.sh" --source prove |
    jq -c --argjson records "$1" '[.probes[] | select(.probe as $name | any($records[]; .probe == $name))] | sort_by(.probe)'
}
result=$(bash "$here/uid.sh" databases pg node1 '' 999 999 | jq -s .)
same_text 'three uid paths' 3 "$(jq length <<<"$result")"
same_text 'missing root paths cannot prove denial' 2 "$(jq '[.[] | select(.ok == false and .value == "error" and (.actual | contains("missing as root")))] | length' <<<"$result")"
same 'existing data denial' '{"probe":"uid-999 pgdata-host-path","target":"pg-test","value":"denied","ok":true}' \
  "$(jq -c '.[1] | {probe, target, value, ok}' <<<"$result")"
same 'the mapped uid is in the target, not the name' "{\"probe\":\"uid-mapped socket-host-path\",\"target\":\"pg-test uid $((uid_base + 999))\"}" \
  "$(jq -c '.[2] | {probe, target}' <<<"$result")"
same_text 'the expected text names no path' 'Permission denied' "$(jq -r 'map(.expected) | unique | join(", ")' <<<"$result")"
same 'names and texts as in the desired document' "$(desired_rows "$result" | jq -c 'map({probe, expected})')" \
  "$(jq -c 'map({probe, expected}) | sort_by(.probe)' <<<"$result")"
result=$(no_pods=true bash "$here/uid.sh" databases pg node1 '' 999 999 | jq -s .)
same 'no local pods fail' '{"probe":"uid-probes","target":"node1","value":"not found","ok":false}' \
  "$(jq -c '.[0] | {probe, target, value, ok}' <<<"$result")"
result=$(no_process=true bash "$here/uid.sh" databases pg node1 '' 999 999 | jq -s .)
same_text 'no postmaster fails' 'not found' "$(jq -r '.[0].value' <<<"$result")"
# A uid and a gid that differ, on a node seen under a root directory where
# every path exists but the socket under the process root.
root=$data_dir/node
mkdir -p "$root/data/pgdata" "$root/var/lib/kubelet/pods/missing-pod/volumes/kubernetes.io~empty-dir/scratch-data/run"
touch "$root/data/pgdata/PG_VERSION" "$root/var/lib/kubelet/pods/missing-pod/volumes/kubernetes.io~empty-dir/scratch-data/run/.s.PGSQL.5432"
: >"$setpriv_log"
result=$(data_dir=/data bash "$here/uid.sh" databases pg node1 "$root" 1001 1002 | jq -s .)
same 'uid and gid differ: the probes as the given uid and gid' '["uid-1001 socket-proc-root", "uid-1001 pgdata-host-path", "uid-mapped socket-host-path"]' \
  "$(jq -c 'map(.probe)' <<<"$result")"
same_text 'uid and gid differ: the data as uid and gid, the socket as the mapped uid and gid' \
  "$(printf '%s\n' --reuid=1001 --regid=1002 "--reuid=$((uid_base + 1001))" "--regid=$((gid_base + 1002))" | paste -d ' ' - -)" \
  "$(cat "$setpriv_log")"
same_text 'uid and gid differ: the target names the mapped uid' "pg-test uid $((uid_base + 1001))" "$(jq -r '.[2].target' <<<"$result")"
# Both socket commands pass the helper text as the bash -c argument.
# shellcheck disable=SC2016
same_text 'the mapped socket probe passes the root-read helper text' 1 \
  "$(command grep -Fc 'bash -c "$socket_text" socket.sh "$socket_dir"' "$here/uid.sh")"
# shellcheck disable=SC2016
same_text 'helper is read before dropping uid' 'socket_text=$(<"$here/socket.sh")' \
  "$(command grep -F 'socket_text=' "$here/uid.sh")"
finish
