#!/usr/bin/env bash
# Checks login targets, certificate input and positive controls with command fixtures.
# Usage: bash login.test.sh
# Exit: 0 all assertions pass, 1 an assertion fails, nonzero on a test error.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

kubectl() {
  case $* in
    *'cluster pg'*)
      cat <<'JSON'
{"spec":{"postgresql":{"pg_hba":["hostssl orders orders all cert"]}}}
JSON
      ;;
    *'secret pg-replication'*)
      cat <<'JSON'
{"data":{"tls.crt":"Y2VydGlmaWNhdGU=","tls.key":"a2V5"}}
JSON
      ;;
    *'service pg-rw-lb'*)
      cat <<'JSON'
{"spec":{"ports":[{"port":5432}]},"status":{"loadBalancer":{"ingress":[{"ip":"192.0.2.1"},{"hostname":"pg.test"}]}}}
JSON
      ;;
    *'service pg-read-lb'*)
      cat <<'JSON'
{"spec":{"ports":[{"port":5433}]},"status":{"loadBalancer":{"ingress":[{"ip":"192.0.2.1"}]}}}
JSON
      ;;
    *'service pg-empty-lb'*) echo '{"spec":{"ports":[{"port":5432}]},"status":{"loadBalancer":{}}}' ;;
    *) return 2 ;;
  esac
}
# Only the variables login.sh sets reach psql, not the caller's below.
only_set_variables() { [[ -z ${PGHOST-}${PGSSLMODE-}${PGSERVICE-} && $PGCONNECT_TIMEOUT == 5 ]]; }
psql() {
  only_set_variables || return 2
  case ${!#} in
    *password=*) echo 'pg_hba.conf rejects connection'; return 2 ;;
    *user=orders*) echo 'connection requires a valid client certificate'; return 2 ;;
    *) return 2 ;;
  esac
}
python3() {
  shift
  only_set_variables || return 2
  [[ $(cat "$PGSSLCERT") == certificate ]] || return 2
  [[ $(cat) == key ]] || return 2
  case ${!#} in
    *user=orders*) echo 'certificate authentication failed for user "orders"'; return 2 ;;
    *dbname=orders*) echo 'pg_hba.conf rejects connection'; return 2 ;;
    *dbname=postgres*) echo streaming_replica ;;
    *) return 2 ;;
  esac
}
export -f kubectl only_set_variables psql python3
export PGHOST=203.0.113.9 PGSSLMODE=disable PGSERVICE=other PGCONNECT_TIMEOUT=60
# desired_rows RECORDS: the rows of the desired prove document, from
# scripts/desired, for the probes in RECORDS, sorted by name.
desired_rows() {
  jq -n '{cluster: {name: "pg", namespace: "databases", instances: 3}, caSecret: "client-ca",
          rwLoadBalancer: {name: "pg-rw-lb"}, network: {operatorNamespace: "cnpg-system", otelNamespace: "otel"},
          replication: {commonName: "pg-replication"}, databases: [{name: "orders", role: "orders", clientCNs: []}]}' |
    bash "$here/../../desired/desired.sh" --source prove |
    jq -c --argjson records "$1" '[.probes[] | select(.probe as $name | any($records[]; .probe == $name))] | sort_by(.probe)'
}
result=$(bash "$here/login.sh" databases pg pg-rw-lb pg-read-lb | jq -s .)
same_text 'six probes per target' 18 "$(jq length <<<"$result")"
same_text 'the rw addresses, then the read address' '192.0.2.1:5432 pg.test:5432 192.0.2.1:5433' \
  "$(jq -r 'map(select(.probe == "password-tls").target) | join(" ")' <<<"$result")"
same_text 'logins and controls match' true "$(jq 'all(.ok)' <<<"$result")"
same_text 'names without addresses' \
  'password-tls password-no-tls tls-no-client-cert replication-cert-as-orders replication-cert-as-streaming_replica control-replication-cert' \
  "$(jq -r '[.[0:6][].probe] | join(" ")' <<<"$result")"
same_text 'denials denied, the control allowed' 'denied denied denied denied denied allowed' \
  "$(jq -r '[.[0:6][].value] | join(" ")' <<<"$result")"
same_text 'hostname retained as the target' 'pg.test:5432' "$(jq -r '.[6].target' <<<"$result")"
same 'names, texts and values as in the desired document' "$(desired_rows "$result")" \
  "$(jq -c 'map({probe, expected, value, ok}) | unique | sort_by(.probe)' <<<"$result")"
status=0
result=$(bash "$here/login.sh" databases pg pg-rw-lb pg-empty-lb 2>/dev/null) || status=$?
same_text 'a Service without an address exits 2' 2 "$status"
same_text 'a Service without an address has no output' '' "$result"
finish
