#!/usr/bin/env bash
# Runs login, pod-network and host-uid probes, then combines their JSON records.
#
# Usage, with the desired state on stdin:
#   yq -o=json desired.yaml | prove.sh [--node NAME] [--node-root DIR] [--postgres-uid UID]
#
# Exit: 0 all probes match, 1 a probe differs, 2 usage or collection error.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../lib/common.sh"

node=$(hostname)
node_root=
postgres_uid=26

usage() {
  echo "usage: yq -o=json desired.yaml | ${0##*/} [--node NAME] [--node-root DIR] [--postgres-uid 26]" >&2
  exit 2
}

while (($#)); do
  (($# >= 2)) || usage
  case $1 in
    --node) node=$2 ;;
    --node-root) node_root=$2 ;;
    --postgres-uid) postgres_uid=$2 ;;
    *) usage ;;
  esac
  shift 2
done

[[ $postgres_uid =~ ^[0-9]+$ ]] || usage
for command in jq kubectl psql setpriv pgrep python3; do
  have "$command" || die "$command not found"
done

values=$(jq -c .) || die "the desired state on stdin is not JSON"
[[ -n $values ]] || die "the desired state on stdin is not JSON"
expected() { jq -r -L "$here/../evidence/violations" "include \"expected\"; $1" <<<"$values"; }
[[ $(expected valid_values) == true ]] || die "$(expected values_needed)"
namespace=$(jq -r .cluster.namespace <<<"$values")
cluster=$(jq -r .cluster.name <<<"$values")
names=$(jq -r '.rwLoadBalancer.name, (.readLoadBalancer.name // empty)' <<<"$values")
mapfile -t lb_services <<<"$names"

((EUID == 0)) || die "run as root"

collected_at=$(collected_at)

log "login probes"
login=$(bash "$here/login/login.sh" "$namespace" "$cluster" "${lb_services[@]}") || exit 2
log "pod probes"
pod=$(bash "$here/pod/pod.sh" "$namespace" "$cluster" "${lb_services[@]}") || exit 2
log "uid probes on node $node"
uid=$(bash "$here/uid/uid.sh" "$namespace" "$cluster" "$node" "$node_root" "$postgres_uid") || exit 2

output=$(printf '%s\n' "$login" "$pod" "$uid" |
  jq -s --arg collected_at "$collected_at" --arg node "$node" --arg namespace "$namespace" \
    --arg cluster "$cluster" -f "$here/output.jq") || exit 2
printf '%s\n' "$output"

if jq -e '.probes | all(.ok)' <<<"$output" >/dev/null; then
  log "all probes ok"
else
  log "some probes failed"
  exit 1
fi
