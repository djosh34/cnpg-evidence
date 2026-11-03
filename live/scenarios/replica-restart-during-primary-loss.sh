#!/usr/bin/env bash
# A replica restarts while the primary is lost. The primary's node stops with
# docker stop -t 0; 10 s later, before any promotion, a replica's postgres
# container is killed on its node with crictl, as a crash or an OOM kill of
# PostgreSQL ends it, and the kubelet starts it again. Another instance must
# become primary by itself and, with the writer, take a write within 180 s of
# the stop. The node starts again 120 s after the stop, and every instance
# must be ready and streaming within 10 min of that.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

KILL_SECONDS=10
DOWN_SECONDS=120

restarts_of() {
  k get pod "$1" -n "$NS" -o jsonpath='{.status.containerStatuses[?(@.name=="postgres")].restartCount}'
}

# The postgres container of instance $1 runs again after a restart.
restarted() {
  local count
  count=$(restarts_of "$1")
  ((count > RESTARTS)) || { echo "restart count of $1: $count" >&2; return 1; }
  [[ $(k get pod "$1" -n "$NS" -o jsonpath='{.status.containerStatuses[?(@.name=="postgres")].state.running}') ]] ||
    { echo "the postgres container of $1 does not run" >&2; return 1; }
}

wait_for 600 "three ready instances, two streaming replicas" settled
old=$(primary)
node=$(node_of "$old")
replica=$(instances | awk -v p="$old" '$1 != p && !found++ {print $1}')
replica_node=$(node_of "$replica")
container=$(k get pod "$replica" -n "$NS" -o jsonpath='{.status.containerStatuses[?(@.name=="postgres")].containerID}')
container=${container#containerd://}
[[ -n $container ]] || fail "no postgres container ID for $replica"
RESTARTS=$(restarts_of "$replica")
use_api_of "$replica_node"
start_monitoring "$replica_node"
start_client

T0=$(now_ms)
docker stop -t 0 "$node" >/dev/null
log "stopped $node, the node of primary $old"
sleep_until "$KILL_SECONDS"
[[ $(cluster_field targetPrimary) == "$old" ]] ||
  fail "a promotion started before the replica's restart: target primary $(cluster_field targetPrimary)"
docker exec "$replica_node" crictl stop --timeout 0 "$container" >/dev/null
KILLED=$(now_ms)
log "killed the postgres container of replica $replica on $replica_node"
wait_for 300 "the postgres container of $replica started again" restarted "$replica"
RESTARTED=$(now_ms)
wait_for 600 "a primary other than $old" primary_not "$old"
promoted=$(now_ms)
new=$(primary)
log "new primary $new"
if [[ $WRITER == on ]]; then
  wait_first_write "$new" 180
fi

sleep_until "$DOWN_SECONDS"
docker start "$node" >/dev/null
STARTED=$(now_ms)
log "started $node"
wait_back
finish

summary "### replica-restart-during-primary-loss, writer $WRITER"
summary ""
row "Seconds after the stop of $node, the node of primary $old" ""
summary "|---|---|"
row "postgres container of replica $replica killed" "$(secs "$KILLED")"
row "it runs again" "$(secs "$RESTARTED")"
row "$new primary" "$(secs "$promoted")"
if [[ $WRITER == on ]]; then
  row "first write on $new" "$(secs "$FIRST_WRITE")"
fi
row "$node started" "$(secs "$STARTED")"
common_rows
print_summary
