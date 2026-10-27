#!/usr/bin/env bash
# Builds the desired document of evidence.sh, host-check.sh or prove.sh from
# the desired values alone, in the shape of the script's actual document. It
# needs no cluster, host or network access.
#
# Usage, with the desired state on stdin:
#   yq -o=json desired.yaml | scripts/desired/desired.sh --ca client-ca.pem
#   yq -o=json desired.yaml | scripts/desired/desired.sh --source host-check
#   yq -o=json desired.yaml | scripts/desired/desired.sh --source prove [--postgres-uid 26]
#
# Prints one JSON document. Exit 0, or 2 on any error, with nothing on stdout.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../lib/common.sh"
expected_dir=$here/../evidence/violations

usage() {
  echo "usage: yq -o=json desired.yaml | ${0##*/} [--source evidence|host-check|prove] [--ca client-ca.pem] [--postgres-uid 26]" >&2
  exit 2
}

source=evidence
ca_file=
postgres_uid=26
while (($#)); do
  (($# >= 2)) || usage
  case $1 in
    --source) source=$2 ;;
    --ca) ca_file=$2 ;;
    --postgres-uid) postgres_uid=$2 ;;
    *) usage ;;
  esac
  shift 2
done
case $source in
  evidence) [[ -n $ca_file ]] || usage ;;
  host-check | prove) [[ -z $ca_file ]] || usage ;;
  *) usage ;;
esac
[[ $postgres_uid =~ ^[0-9]+$ ]] || usage

for tool in jq openssl; do
  have "$tool" || die "$tool not found"
done

values=$(jq -c .) || die "the desired state on stdin is not JSON"
expected() { jq -r -L "$expected_dir" "include \"expected\"; $1" <<<"$values"; }
[[ $(expected valid_values) == true ]] || die "$(expected values_needed)"

case $source in
  evidence)
    [[ -r $ca_file ]] || die "cannot read $ca_file"
    certificates=$(bash "$here/../evidence/client-ca/certificates.sh" <"$ca_file") || exit 2
    [[ $certificates != "[]" ]] || die "no certificate in $ca_file"
    document=$(jq -L "$expected_dir" --slurpfile certificates <(echo "$certificates") -f "$here/evidence.jq" <<<"$values") ||
      exit 2
    ;;
  host-check)
    document=$(jq -n -f "$here/host-check.jq") || exit 2
    ;;
  prove)
    [[ $(jq '.databases | length' <<<"$values") -gt 0 ]] || die "prove needs at least one database in the desired state"
    document=$(jq --arg postgres_uid "$postgres_uid" -f "$here/prove.jq" <<<"$values") || exit 2
    ;;
esac

echo "$document"
