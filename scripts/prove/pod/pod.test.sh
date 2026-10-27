#!/usr/bin/env bash
# Checks pod controls, service results and collection errors with command fixtures.
# Usage: bash pod.test.sh
# Exit: 0 all assertions pass, 1 an assertion fails, nonzero on a test error.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

kubectl() {
  case $* in
    *'get -o json cluster pg'*) echo '{"spec":{"imageName":"postgres:test"}}' ;;
    *'get service kubernetes'*) printf 10.43.0.1 ;;
    *'get -o json pods'*) echo '{"items":[{"status":{"podIP":"10.42.0.1"}}]}' ;;
    *'get -o json service pg-rw-lb'*)
      cat <<'JSON'
{"spec":{"ports":[{"port":5432,"nodePort":30000}]},"status":{"loadBalancer":{"ingress":[{"ip":"192.0.2.1"}]}}}
JSON
      ;;
    'get nodes -o json')
      cat <<'JSON'
{"items":[{"status":{"addresses":[{"type":"InternalIP","address":"192.0.2.2"}]}}]}
JSON
      ;;
    'create namespace prove-'* | 'delete namespace prove-'*) return 0 ;;
    *'run probe'*) [[ ${pod_failure:-} != run ]] ;;
    *'wait pod/probe'*) [[ ${pod_failure:-} != wait ]] ;;
    *'logs probe')
      cat <<TEXT
10.43.0.1:443 connected
10.42.0.1:5432 timeout
10.42.0.1:8000 Connection refused
10.42.0.1:9187 timeout
lb 192.0.2.1:5432 ${service_result:-FATAL: pg_hba.conf rejects connection}
nodeport 192.0.2.2:30000 ${service_result:-FATAL: pg_hba.conf rejects connection}
TEXT
      ;;
    *) return 2 ;;
  esac
}
export -f kubectl
# desired_rows RECORDS: the rows of the desired prove document, from
# scripts/desired, for the probes in RECORDS, sorted by name.
desired_rows() {
  jq -n '{cluster: {name: "pg", namespace: "databases", instances: 3}, caSecret: "client-ca",
          rwLoadBalancer: {name: "pg-rw-lb"}, network: {operatorNamespace: "cnpg-system", otelNamespace: "otel"},
          replication: {commonName: "pg-replication"}, databases: [{name: "orders", role: "orders", clientCNs: []}]}' |
    bash "$here/../../desired/desired.sh" --source prove |
    jq -c --argjson records "$1" '[.probes[] | select(.probe as $name | any($records[]; .probe == $name))] | sort_by(.probe)'
}
result=$(bash "$here/pod.sh" databases pg pg-rw-lb | jq -s .)
same_text 'pod controls and policy probes' true "$(jq 'length == 6 and all(.ok)' <<<"$result")"
same 'names without addresses, targets with them' \
  '[["control-other-namespace","10.43.0.1:443","allowed"],["other-namespace-5432","10.42.0.1:5432","denied"],
    ["other-namespace-8000","10.42.0.1:8000","denied"],["other-namespace-9187","10.42.0.1:9187","denied"],
    ["other-namespace-lb","192.0.2.1:5432","denied"],["other-namespace-nodeport","192.0.2.2:30000","denied"]]' \
  "$(jq -c 'map([.probe, .target, .value])' <<<"$result")"
same 'names, texts and values as in the desired document' "$(desired_rows "$result")" \
  "$(jq -c 'map({probe, expected, value, ok}) | unique | sort_by(.probe)' <<<"$result")"
for refusal in 'psql: error: connection failed: Connection refused' \
  'psql: error: connection failed: timeout expired'; do
  result=$(service_result=$refusal bash "$here/pod.sh" databases pg pg-rw-lb | jq -s .)
  same_text "$refusal is an accepted service denial" true "$(jq 'all(.ok)' <<<"$result")"
done
for failure in 'succeeded: 1' 'succeeded: pg_hba.conf rejects connection' \
  'succeeded: Connection refused' 'psql: error: could not translate host name' \
  'psql: error: certificate verify failed' 'timeout' 'no result, the pod did not finish'; do
  result=$(service_result=$failure bash "$here/pod.sh" databases pg pg-rw-lb | jq -s .)
  same_text "$failure never proves service denial" 2 \
    "$(jq '[.[] | select(.ok == false)] | length' <<<"$result")"
  same_text "$failure is allowed or error" "$([[ $failure == succeeded* ]] && echo allowed || echo error)" \
    "$(jq -r 'map(select(.probe == "other-namespace-lb"))[0].value' <<<"$result")"
done
for failure in run wait; do
  status=0
  result=$(pod_failure=$failure bash "$here/pod.sh" databases pg pg-rw-lb 2>/dev/null) || status=$?
  same_text "$failure error exits 2" 2 "$status"
  same_text "$failure error has no output" '' "$result"
done
finish
