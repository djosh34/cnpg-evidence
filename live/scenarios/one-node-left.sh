#!/usr/bin/env bash
# Two of three nodes are lost: the primary's node and one replica's node stop
# with docker stop -t 0 and start again 120 s later. With one etcd member of
# three there is no Kubernetes API, so nothing is promoted, and writes stop,
# as every commit needs a second instance. The last node runs a replica. Its
# read port must answer every probe while the two nodes are down, and with
# the writer no write may be acknowledged then. After both nodes start, every
# instance must be ready and streaming within 10 min, and with the writer the
# primary must take a write within 180 s.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

DOWN_SECONDS=120
WRITE_GAP_LIMIT=$((DOWN_SECONDS + 180))
# A write that started before the stop may still be acknowledged within the
# client's 5 s limit.
IN_FLIGHT_MS=5000

wait_for 600 "three ready instances, two streaming replicas" settled
old=$(primary)
node=$(node_of "$old")
replica=$(instances | awk -v p="$old" '$1 != p {print $1; exit}')
replica_node=$(node_of "$replica")
last=$(instances | awk -v p="$old" -v r="$replica" '$1 != p && $1 != r {print $2; exit}')
use_api_of "$last"
start_monitoring "$last"
start_client

T0=$(now_ms)
docker stop -t 0 "$node" "$replica_node" >/dev/null
log "stopped $node, the node of primary $old, and $replica_node, the node of replica $replica"
sleep_until "$DOWN_SECONDS"
docker start "$node" "$replica_node" >/dev/null
STARTED=$(now_ms)
log "started $node and $replica_node"

reads=$(reads_between "$last" "$T0" "$STARTED")
read -r ok failed <<<"$reads"
((ok > 0 && failed == 0)) ||
  fail "the read port of $last, the last node, answered $ok and failed $failed probes while the other nodes were down; the first failure: $(awk -v ip="$(node_ip "$last")" -v t0="$T0" '$1 >= t0 && $2 == ip && $3 == "fail" {print; exit}' "$READ_LOG")"
if [[ $WRITER == on ]]; then
  acked=$(writes_between $((T0 + IN_FLIGHT_MS)) "$STARTED")
  ((acked == 0)) || fail "$acked writes were acknowledged while only $last ran"
fi
wait_back
p=$(primary)
if [[ $WRITER == on ]]; then
  wait_first_write "$p" 180 "$STARTED"
fi
finish

summary "### one-node-left, writer $WRITER"
summary ""
row "Seconds after the stop of $node, the node of primary $old, and $replica_node" ""
summary "|---|---|"
row "read probes of $last while the two nodes were down" "$ok answered, none failed"
if [[ $WRITER == on ]]; then
  row "acknowledged writes while the two nodes were down" "none"
fi
row "$node and $replica_node started" "$(secs "$STARTED")"
row "primary after the start" "$p"
if [[ $WRITER == on ]]; then
  row "first write on $p after the start" "$(secs "$FIRST_WRITE")"
fi
common_rows
print_summary
