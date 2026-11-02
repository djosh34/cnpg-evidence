#!/usr/bin/env bash
# A replica's node is lost for 6 min: its container stops with docker stop
# -t 0 and starts again 360 s later. The primary must stay where it is, and
# with the writer, writes must not stop for more than 180 s. Every instance
# must be ready and streaming within 10 min of the start.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

DOWN_SECONDS=360

wait_for 600 "three ready instances, two streaming replicas" settled
p=$(primary)
replica=$(instances | awk -v p="$p" '$1 != p {print $1; exit}')
node=$(node_of "$replica")
use_api_of "$(other_node "$node")"
start_monitoring "$(other_node "$node")"
expect_alert CNPGReplicaDown "$replica"
start_client

T0=$(now_ms)
docker stop -t 0 "$node" >/dev/null
log "stopped $node, the node of replica $replica"
sleep_until "$DOWN_SECONDS"
primary_is "$p" || fail "the primary moved away from $p while $node was down"
docker start "$node" >/dev/null
STARTED=$(now_ms)
log "started $node"
wait_back
primary_is "$p" || fail "the primary moved away from $p after $node started"
finish

summary "### replica-node-loss, writer $WRITER"
summary ""
row "Seconds after the stop of $node, the node of replica $replica" ""
summary "|---|---|"
row "$node started, $p still primary" "$(secs "$STARTED")"
common_rows
print_summary
