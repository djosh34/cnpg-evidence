#!/usr/bin/env bash
# The primary's node is lost: its container stops with docker stop -t 0.
# Another instance must become primary and, with the writer, take a write
# within 180 s of the stop. The node starts again 120 s after the stop, and
# every instance must be ready and streaming within 10 min of that.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

DOWN_SECONDS=120

wait_for 600 "three ready instances, two streaming replicas" settled
old=$(primary)
node=$(node_of "$old")
use_api_of "$(other_node "$node")"
start_monitoring "$(other_node "$node")"
start_client

T0=$(now_ms)
docker stop -t 0 "$node" >/dev/null
log "stopped $node, the node of primary $old"
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

summary "### primary-node-loss, writer $WRITER"
summary ""
row "Seconds after the stop of $node, the node of primary $old" ""
summary "|---|---|"
row "$new primary" "$(secs "$promoted")"
if [[ $WRITER == on ]]; then
  row "first write on $new" "$(secs "$FIRST_WRITE")"
fi
row "$node started" "$(secs "$STARTED")"
common_rows
print_summary
