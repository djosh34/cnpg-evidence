#!/usr/bin/env bash
# Runs certificate and password login probes against every address of the
# rw LoadBalancer Service.
# Usage: login.sh NAMESPACE CLUSTER LB_SERVICE
# Exit: 0 records collected (including failed probes), 2 collection error.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../probe.sh"

namespace=$1
cluster=$2
lb_service=$3
psql_command=(psql -w -X -At -c 'select current_user')

cluster_state=$(kjson "$namespace" cluster "$cluster")
application=$(jq -r -f "$here/application.jq" <<<"$cluster_state")
[[ -n $application ]] || die "no hostssl cert line in the Cluster pg_hba"
read -r database role <<<"$application"

secret=$(kjson "$namespace" secret "$cluster-replication")
certificate=$(jq -er '.data["tls.crt"] | @base64d' <<<"$secret")
key=$(jq -er '.data["tls.key"] | @base64d' <<<"$secret")
with_key() {
  local certificate_fd
  exec {certificate_fd}< <(printf '%s\n' "$certificate")
  printf '%s\n' "$key" | PGSSLCERT=/proc/self/fd/$certificate_fd python3 "$here/key.py" "$@"
}

service_targets=$(kjson "$namespace" service "$lb_service" | jq -r -f "$here/targets.jq")
[[ -n $service_targets ]] || die "service $lb_service has no load balancer address"
mapfile -t targets <<<"$service_targets"

for target in "${targets[@]}"; do
  connection="host=${target%:*} port=${target##*:}"
  deny password-tls "$target" "refused by pg_hba reject" 'pg_hba\.conf rejects connection' \
    "${psql_command[@]}" "$connection dbname=postgres user=postgres password=prove-sh sslmode=require"
  deny password-no-tls "$target" "refused by pg_hba reject" 'pg_hba\.conf rejects connection' \
    "${psql_command[@]}" "$connection dbname=postgres user=postgres password=prove-sh sslmode=disable"
  deny tls-no-client-cert "$target" "refused, $role to $database needs a client certificate" \
    'connection requires a valid client certificate' \
    "${psql_command[@]}" "$connection dbname=$database user=$role sslmode=require"
  deny "replication-cert-as-$role" "$target" "refused, the certificate CN does not map to $role" \
    "certificate authentication failed for user \"$role\"" \
    with_key "${psql_command[@]}" "$connection dbname=$database user=$role sslmode=require"
  allow control-replication-cert "$target" "logs in as streaming_replica to postgres (CNPG's fixed line)" \
    '^streaming_replica$' \
    with_key "${psql_command[@]}" "$connection dbname=postgres user=streaming_replica sslmode=require"
done
