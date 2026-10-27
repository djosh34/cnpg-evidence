#!/usr/bin/env bash
# Attempts socket, token, environment and data access as the host postgres uid
# and the pod's mapped uid, checking path existence as root before each attempt.
# Usage: uid.sh NAMESPACE CLUSTER NODE NODE_ROOT POSTGRES_UID
# Exit: 0 records collected (including failed probes), 2 collection error.
set -euo pipefail
shopt -s inherit_errexit
shopt -s nullglob

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../probe.sh"

namespace=$1
cluster=$2
node=$3
node_root=$4
postgres_uid=$5
psql_command=(psql -w -X -At -c 'select current_user')
read_command=(dd of=/dev/null bs=1 count=1 status=none)
# Read the socket helper text before changing uid.
socket_text=$(<"$here/socket.sh")

deny_path() {
  local probe=$1 target=$2 uid=$3 gid=$4 path=$5
  shift 5

  if [[ ! -e $path ]]; then
    add_probe "$probe" "$target" "Permission denied" denied error "$path missing as root, nothing proven"
    return
  fi
  deny "$probe" "$target" "Permission denied" 'Permission denied' as_uid "$uid" "$gid" "$@"
}

pods=$(kjson "$namespace" pods -l "cnpg.io/cluster=$cluster,cnpg.io/podRole=instance" \
  --field-selector "spec.nodeName=$node" | jq -r '.items[] | "\(.metadata.name) \(.metadata.uid)"')
expected_instance="an instance of $cluster on this node, with its postgres process"
if [[ -z $pods ]]; then
  add_probe uid-probes "$node" "$expected_instance" found "not found" "no instance pod found"
  exit 0
fi

while read -r pod pod_uid; do
  if ! pid=$(bash "$here/postmaster.sh" "$pod_uid"); then
    add_probe uid-probes "$pod" "$expected_instance" found "not found" "no postgres process for pod $pod_uid"
    continue
  fi

  process_root=/proc/$pid/root
  volumes=$node_root/var/lib/kubelet/pods/$pod_uid/volumes
  socket_dir=$volumes/kubernetes.io~empty-dir/scratch-data/run
  tokens=("$volumes"/kubernetes.io~projected/kube-api-access-*/token)
  token=${tokens[0]:-$volumes/kubernetes.io~projected/token}
  volume=$(kjson "$namespace" pvc "$pod" | jq -r .spec.volumeName)
  data_path=$(kubectl get pv "$volume" -o json | jq -r '.spec.local.path // .spec.hostPath.path')
  pgdata=$node_root$data_path/pgdata/PG_VERSION
  uid_base=$(awk '$1 == 0 {print $2}' "/proc/$pid/uid_map")
  gid_base=$(awk '$1 == 0 {print $2}' "/proc/$pid/gid_map")
  mapped_uid=$((uid_base + postgres_uid))
  mapped_gid=$((gid_base + postgres_uid))
  log "$pod: pid $pid, mapped uid $mapped_uid"

  deny_path "uid-$postgres_uid socket-proc-root" "$pod" "$postgres_uid" "$postgres_uid" \
    "$process_root/controller/run/.s.PGSQL.5432" \
    "${psql_command[@]}" "host=$process_root/controller/run dbname=postgres user=postgres"
  deny_path "uid-$postgres_uid token-proc-root" "$pod" "$postgres_uid" "$postgres_uid" \
    "$process_root/run/secrets/kubernetes.io/serviceaccount/token" \
    "${read_command[@]}" "if=$process_root/run/secrets/kubernetes.io/serviceaccount/token"
  deny_path "uid-$postgres_uid environ" "$pod" "$postgres_uid" "$postgres_uid" \
    "/proc/$pid/environ" "${read_command[@]}" "if=/proc/$pid/environ"
  deny_path "uid-$postgres_uid socket-host-path" "$pod" "$postgres_uid" "$postgres_uid" \
    "$socket_dir/.s.PGSQL.5432" bash -c "$socket_text" socket.sh "$socket_dir"
  deny_path "uid-$postgres_uid token-host-path" "$pod" "$postgres_uid" "$postgres_uid" \
    "$token" "${read_command[@]}" "if=$token"
  deny_path "uid-$postgres_uid pgdata-host-path" "$pod" "$postgres_uid" "$postgres_uid" \
    "$pgdata" "${read_command[@]}" "if=$pgdata"
  deny_path "uid-mapped socket-host-path" "$pod uid $mapped_uid" "$mapped_uid" "$mapped_gid" \
    "$socket_dir/.s.PGSQL.5432" bash -c "$socket_text" socket.sh "$socket_dir"
done <<<"$pods"
