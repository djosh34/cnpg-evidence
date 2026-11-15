#!/usr/bin/env bash
# Who can do what to one CNPG cluster, compared with samples/desired.yaml: every
# difference is a violation. It only reads: kubectl get, one kubectl create of
# SubjectAccessReviews, which the API server answers and does not store,
# kubectl exec psql as postgres in READ ONLY transactions, and a local openssl
# handshake with the metrics port through kubectl port-forward.
#
# Usage, with the desired state on stdin:
#   yq -o=json samples/desired.yaml | scripts/evidence/evidence.sh --ca client-ca.pem [--part PART]
#
# With --part it reads and judges only that part: client-ca, logins,
# postgres, pods, tls or kubernetes. Without it, every part and the software
# versions.
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

parts=(client-ca logins postgres pods tls kubernetes)

usage() {
  echo "usage: yq -o=json desired.yaml | ${0##*/} --ca client-ca.pem [--part PART], PART one of: ${parts[*]}" >&2
  exit 2
}

[[ ($# -eq 2 || $# -eq 4) && $1 == --ca ]] || usage
ca_file=$2
part=
if (($# == 4)); then
  [[ $3 == --part ]] || usage
  part=$4
  [[ " ${parts[*]} " == *" $part "* ]] || die "no part $part; the parts: ${parts[*]}"
fi
[[ -r $ca_file ]] || die "cannot read $ca_file"

# reads PART: the run reads that part.
reads() { [[ -z $part || $part == "$1" ]]; }

for tool in kubectl jq openssl timeout base64; do
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

# A part it does not read stays null, and leaves its facts out.
postgres=null logins=null client_ca=null tls=null software=null kubernetes=null
if reads postgres; then
  log "reading PostgreSQL's roles and databases on $primary"
  postgres=$(bash "$here/postgres/postgres.sh" "$namespace" "$primary") || exit 2
fi
if reads logins; then
  log "reading pg_hba and pg_ident on ${instances[*]}"
  logins=$(bash "$here/logins/logins.sh" "$namespace" "${instances[@]}") || exit 2
fi
if reads client-ca; then
  log "reading the client CA"
  client_ca=$(bash "$here/client-ca/client-ca.sh" "$namespace" "$cluster") || exit 2
fi
if reads tls; then
  log "reading TLS"
  tls=$(bash "$here/tls/tls.sh" "$namespace" "${instances[@]}") || exit 2
fi
if [[ -z $part ]]; then
  log "reading the versions"
  software=$(bash "$here/software/software.sh" "$namespace" "$operator_namespace" "$primary") || exit 2
fi
if reads kubernetes; then
  log "asking the API server who holds which right"
  kubernetes=$(bash "$here/kubernetes/kubernetes.sh" "$namespace" "$cluster" "$operator_namespace" \
    "$operator_account" "$plugin_account" "$cert_manager_namespace" "${instances[@]}") || exit 2
fi

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
    --arg part "$part" \
    'include "expected";
     def reads($name): $part == "" or $part == $name;
     {
      postgres: $postgres[0],
      certificate_logins: (if reads("logins") then $values[0] | certificate_logins($logins[0].ident) else null end),
      client_ca: $client_ca[0],
      tls: $tls[0],
      kubernetes: ($kubernetes[0] | if . then del(.granted_by) else null end),
      pods_sharing_host_uids: (if reads("pods") then $pods[0].sharing_host_uids else null end),
      software: $software[0],
      details: ({primary: $pods[0].primary, instances: $pods[0].instances}
        + if reads("logins") then {pg_hba: $logins[0].pg_hba, pg_ident: $logins[0].pg_ident} else {} end)
    }
    | with_entries(select(.value != null))'
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
    bash "$here/violations/violations.sh" ${part:+"$part"}
) || exit 2

result=$(
  jq -n --slurpfile facts <(echo "$facts") --slurpfile violations <(echo "$violations") \
    --arg collected_at "$collected_at" --arg name "$cluster" --arg namespace "$namespace" --arg part "$part" \
    '{kind: "actual", source: "evidence", $collected_at, cluster: {$name, $namespace}}
     + (if $part == "" then {} else {$part} end)
     + {status: (if $violations[0] == [] then "pass" else "fail" end), violations: $violations[0]}
     + $facts[0]'
) || exit 2

echo "$result"

if [[ $violations == "[]" ]]; then
  log "no violations"
else
  log "$(jq length <<<"$violations") violations"
  exit 1
fi
