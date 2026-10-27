#!/usr/bin/env bash
# Runs login, pod-network and host-uid probes, then combines their JSON records.
# Usage: prove.sh [--namespace NS] [--cluster NAME] [--lb-service NAME]
#   [--node NAME] [--node-root DIR] [--postgres-uid UID]
# Exit: 0 all probes match, 1 a probe differs, 2 usage or collection error.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../lib/common.sh"

namespace=databases
cluster=pg
lb_service=pg-rw-lb
node=$(hostname)
node_root=
postgres_uid=26

usage() {
  cat >&2 <<EOF
usage: ${0##*/} [--namespace databases] [--cluster pg] [--lb-service pg-rw-lb]
         [--node NAME] [--node-root DIR] [--postgres-uid 26]
EOF
  exit 2
}

while (($#)); do
  (($# >= 2)) || usage
  case $1 in
    --namespace) namespace=$2 ;;
    --cluster) cluster=$2 ;;
    --lb-service) lb_service=$2 ;;
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
((EUID == 0)) || die "run as root"

export PGCONNECT_TIMEOUT=5
collected_at=$(collected_at)

log "login probes"
login=$(bash "$here/login/login.sh" "$namespace" "$cluster" "$lb_service") || exit 2
log "pod probes"
pod=$(bash "$here/pod/pod.sh" "$namespace" "$cluster" "$lb_service") || exit 2
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
