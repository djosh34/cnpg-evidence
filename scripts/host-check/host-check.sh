#!/usr/bin/env bash
# Reads one k3s host's facts and checks accounts, modes and configuration.
# Prints one JSON document after collection completes.
# Usage: host-check.sh [--node NAME] [--postgres-uid N] [--postgres-gid N]
#   [--storage-dir PATH]
# Exit: 0 all checks pass, 1 a check fails, 2 an argument/collection error
#   (with no stdout). Requires root.
set -euo pipefail
shopt -s inherit_errexit nullglob

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/lib.sh"

postgres_uid=26
postgres_gid=26
storage_dir=/var/lib/rancher/k3s/storage
node=

usage() {
  echo "usage: ${0##*/} [--node NAME] [--postgres-uid N] [--postgres-gid N] [--storage-dir $storage_dir]" >&2
  exit 2
}

while (($#)); do
  (($# >= 2)) || usage
  case $1 in
    --postgres-uid) postgres_uid=$2 ;;
    --postgres-gid) postgres_gid=$2 ;;
    --storage-dir) storage_dir=$2 ;;
    --node) node=$2 ;;
    *) usage ;;
  esac
  shift 2
done
[[ $postgres_uid =~ ^[0-9]+$ && $postgres_gid =~ ^[0-9]+$ ]] || usage
have jq || die "jq not found"
((EUID == 0)) || die "run as root"
log "collecting"
collected_at=$(collected_at)

facts=$(bash "$here/collected/collected.sh" "$postgres_uid" "$postgres_gid") || exit 2
checks=$(bash "$here/checks/checks.sh" "$postgres_uid" "$postgres_gid" "$storage_dir" <<<"$facts") || exit 2

output=$(printf '%s\n' "$checks" | jq -s --slurpfile facts <(printf '%s\n' "$facts") \
  --arg collected_at "$collected_at" --arg node "$node" -f "$here/output.jq") || exit 2
printf '%s\n' "$output"

if jq -e 'all(.checks[]; .ok)' <<<"$output" >/dev/null; then
  log "all checks ok"
else
  log "some checks failed"
  exit 1
fi
