#!/usr/bin/env bash
# Who can do what to one CNPG cluster, compared with desired.yaml: every
# difference is a violation. It only reads: kubectl get, one kubectl create of
# SubjectAccessReviews, which the API server answers and does not store, and through
# kubectl exec psql as postgres in READ ONLY transactions and an openssl
# handshake with the metrics port.
#
# Usage, with the desired state on stdin:
#   yq -o=json desired.yaml | scripts/evidence/evidence.sh --ca client-ca.pem
#
# Prints one JSON document. Exit 0 when violations is empty, 1 when not,
# 2 on any error, with nothing on stdout.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../lib/common.sh"

# expected EXPRESSION: a value from violations/expected.jq, with the desired
# values as input.
expected() { jq -r -L "$here/violations" "include \"expected\"; $1" <<<"$values"; }

usage() {
  echo "usage: yq -o=json desired.yaml | ${0##*/} --ca client-ca.pem" >&2
  exit 2
}

[[ $# -eq 2 && $1 == --ca ]] || usage
ca_file=$2
[[ -r $ca_file ]] || die "cannot read $ca_file"

for tool in kubectl jq openssl base64; do
  have "$tool" || die "$tool not found"
done

values=$(jq -c .) || die "the desired state on stdin is not JSON"
[[ -n $values ]] || die "stdin is empty: pipe in desired.yaml as JSON"
[[ $(expected valid_values) == true ]] || die "$(expected values_needed)"
operator_account=$(expected operator_account) || exit 2
plugin_account=$(expected plugin_account) || exit 2
cert_manager_namespace=$(expected cert_manager_namespace) || exit 2

value() { jq -r "$1" <<<"$values"; }
namespace=$(value .cluster.namespace) || exit 2
cluster=$(value .cluster.name) || exit 2
operator_namespace=$(value .network.operatorNamespace) || exit 2

expected_ca=$(bash "$here/client-ca/certificates.sh" <"$ca_file") || exit 2
[[ $expected_ca != "[]" ]] || die "no certificate in $ca_file"

collected_at=$(collected_at)
log "reading the instance pods of $namespace/$cluster"
pods=$(bash "$here/pods/pods.sh" "$namespace" "$cluster") || exit 2
primary=$(jq -r .primary <<<"$pods") || exit 2
mapfile -t instances < <(jq -r '.instances[]' <<<"$pods") || exit 2
((${#instances[@]} > 0)) || die "no instance pods for $namespace/$cluster"
[[ " ${instances[*]} " == *" $primary "* ]] || die "primary $primary is not among the instance pods"

log "reading PostgreSQL on ${instances[*]}"
postgres=$(bash "$here/postgres/postgres.sh" "$namespace" "$primary") || exit 2
logins=$(bash "$here/logins/logins.sh" "$namespace" "${instances[@]}") || exit 2

log "reading the client CA, TLS and versions"
client_ca=$(bash "$here/client-ca/client-ca.sh" "$namespace" "$cluster") || exit 2
tls=$(bash "$here/tls/tls.sh" "$namespace" "${instances[@]}") || exit 2
software=$(bash "$here/software/software.sh" "$namespace" "$operator_namespace" "$primary") || exit 2

log "asking the API server who holds which right"
kubernetes=$(bash "$here/kubernetes/kubernetes.sh" "$namespace" "$cluster" "$operator_namespace" \
  "$operator_account" "$plugin_account" "$cert_manager_namespace" "${instances[@]}") || exit 2

facts=$(
  jq -n -L "$here/violations" \
    --slurpfile values <(echo "$values") \
    --slurpfile postgres <(echo "$postgres") \
    --slurpfile logins <(echo "$logins") \
    --slurpfile client_ca <(echo "$client_ca") \
    --slurpfile tls <(echo "$tls") \
    --slurpfile kubernetes <(echo "$kubernetes") \
    --slurpfile pods <(echo "$pods") \
    --slurpfile software <(echo "$software") \
    'include "expected";
     {
      postgres: $postgres[0],
      certificate_logins: ($values[0] | certificate_logins($logins[0].ident)),
      client_ca: $client_ca[0],
      tls: $tls[0],
      kubernetes: ($kubernetes[0] | del(.granted_by)),
      pods_sharing_host_uids: $pods[0].sharing_host_uids,
      software: $software[0],
      details: {primary: $pods[0].primary, instances: $pods[0].instances, pg_hba: $logins[0].pg_hba, pg_ident: $logins[0].pg_ident}
    }'
) || exit 2

violations=$(
  jq -n \
    --slurpfile facts <(echo "$facts") \
    --slurpfile values <(echo "$values") \
    --slurpfile expected_ca <(echo "$expected_ca") \
    --slurpfile kubernetes <(echo "$kubernetes") \
    --arg operator_account "$operator_account" \
    --arg plugin_account "$plugin_account" \
    '{facts: $facts[0], values: $values[0], expected_ca: $expected_ca[0], granted_by: $kubernetes[0].granted_by,
      $operator_account, $plugin_account}' |
    bash "$here/violations/violations.sh"
) || exit 2

result=$(
  jq -n --slurpfile facts <(echo "$facts") --slurpfile violations <(echo "$violations") \
    --arg collected_at "$collected_at" --arg name "$cluster" --arg namespace "$namespace" \
    '{kind: "actual", source: "evidence", $collected_at, cluster: {$name, $namespace},
      status: (if $violations[0] == [] then "pass" else "fail" end), violations: $violations[0]}
     + $facts[0]'
) || exit 2

echo "$result"

if [[ $violations == "[]" ]]; then
  log "no violations"
else
  log "$(jq length <<<"$violations") violations"
  exit 1
fi
