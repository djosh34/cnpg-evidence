#!/usr/bin/env bash
# A replica, and then a former primary, rejoin by themselves after more than
# wal_keep_size of WAL was written while their node was down, so they must
# read WAL from the object store. The scenario first sets wal_keep_size to
# 64MB with helm upgrade, for this scenario only.
#
# 1. A replica's node stops. The primary writes 256 MB of WAL and makes
#    checkpoints until the WAL file it wrote at the stop is gone from its
#    pg_wal. The node starts again.
# 2. The primary's node stops. Another instance becomes primary, writes
#    256 MB and makes checkpoints until the WAL file of the timeline switch is
#    gone from its pg_wal. The node starts again; the former primary rewinds.
#
# After each start every instance must be ready and streaming within 10 min.
# With the writer, a new primary must take a write within 180 s of the stop.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

KEEP=64MB
LOAD_MB=256

wal_keep_size_is() {
  local pod value
  for pod in $(instances | awk '{print $1}'); do
    value=$(psql_on "$pod" -c 'show wal_keep_size')
    [[ $value == "$1" ]] || { echo "wal_keep_size on $pod: $value" >&2; return 1; }
  done
}

timeout 300 helm upgrade "$CLUSTER" "$REPO/samples/chart" --namespace "$NS" \
  -f "$REPO/desired.yaml" -f "$LIVE_DIR/values.yaml" --set cluster.walKeepSize="$KEEP" >/dev/null
wait_for 300 "wal_keep_size $KEEP on every instance" wal_keep_size_is "$KEEP"
wait_for 600 "three ready instances, two streaming replicas" settled
start_client

summary "### rejoin-from-archive, writer $WRITER, wal_keep_size $KEEP"

# 1. A replica.
p=$(primary)
replica=$(instances | awk -v p="$p" '$1 != p {print $1; exit}')
node=$(node_of "$replica")
use_api_of "$(other_node "$node")"
T0=$(now_ms)
REPLICA_LOSS=$T0
docker stop -t 0 "$node" >/dev/null
log "stopped $node, the node of replica $replica"
# The replica has nothing past the primary's WAL file now; once that file is
# gone, so is every file the replica needs.
needed=$(wal_file "$p" "$(psql_on "$p" -c 'select pg_current_wal_lsn()')")
written=$(write_wal "$p" "$LOAD_MB")
wait_for 120 "WAL file $needed gone from the pg_wal of $p" wal_file_gone "$p" "$needed"
GONE=$(now_ms)
docker start "$node" >/dev/null
STARTED=$(now_ms)
log "started $node"
wait_back
summary ""
row "Seconds after the stop of $node, the node of replica $replica" ""
summary "|---|---|"
row "$written MB written; $needed, the WAL file of the stop, gone from the pg_wal of $p" "$(secs "$GONE")"
row "$node started" "$(secs "$STARTED")"
row "every instance ready and streaming" "$(secs "$BACK")"

# 2. A former primary.
old=$(primary)
node=$(node_of "$old")
use_api_of "$(other_node "$node")"
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
# The former primary needs WAL of the new timeline from where it split off,
# which is before the new primary's WAL file now.
switched=$(wal_file "$new" "$(psql_on "$new" -c 'select pg_current_wal_lsn()')")
written=$(write_wal "$new" "$LOAD_MB")
wait_for 120 "WAL file $switched gone from the pg_wal of $new" wal_file_gone "$new" "$switched"
GONE=$(now_ms)
docker start "$node" >/dev/null
STARTED=$(now_ms)
log "started $node"
wait_back
PRIMARY_LOSS=$T0
# The writer's longest gap counts from the replica's loss.
T0=$REPLICA_LOSS
finish
T0=$PRIMARY_LOSS
summary ""
row "Seconds after the stop of $node, the node of primary $old" ""
summary "|---|---|"
row "$new primary" "$(secs "$promoted")"
if [[ $WRITER == on ]]; then
  row "first write on $new" "$(secs "$FIRST_WRITE")"
fi
row "$written MB written; $switched, the WAL file of the timeline switch, gone from the pg_wal of $new" "$(secs "$GONE")"
row "$node started" "$(secs "$STARTED")"
common_rows
print_summary
