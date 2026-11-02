# shellcheck shell=bash disable=SC2034
# A primary node loss and then a switchover, each while the object store is
# broken. live/scenarios/store-refuse.sh and store-hang.sh source this after
# setting STORE_MODE to refuse or hang (see store_break in lib.sh).
#
# Before each event the store breaks and the primary switches WAL twice, so
# it holds WAL the store never got. Within 15 min of the event a new primary
# must be out of recovery with a standby streaming from it, so writes can go
# on, and with the writer it must take a write. The store stays broken
# STORE_HOLD seconds more, after the primary's node has started again 120 s
# after its stop. A former primary with WAL the store never got waits for
# the store before it rejoins, so then the store comes back, and every
# instance must be ready and streaming within 10 min.

RECOVER_SECONDS=900
DOWN_SECONDS=120
STORE_HOLD=60
WRITE_GAP_LIMIT=$RECOVER_SECONDS

# Instance $1 is the primary, out of recovery, and a standby streams from it.
primary_with_standby() {
  primary_is "$1" || return 1
  local n
  n=$(psql_on "$1" -c "select count(*) from pg_stat_replication where state = 'streaming'")
  ((n > 0)) || { echo "no standby streams from $1" >&2; return 1; }
}

# The archiver of instance $1 has WAL waiting.
wal_waiting() {
  local n
  n=$(psql_on "$1" -c "select count(*) from pg_ls_archive_statusdir() where name like '%.ready'")
  ((n > 0)) || { echo "no WAL waits for the archive on $1" >&2; return 1; }
}

# Breaks the store and leaves WAL on primary $1 that the store never got.
break_store() {
  store_break "$STORE_MODE"
  psql_on "$1" -c 'create table if not exists live_load (n int, pad text)'
  for _ in 1 2; do
    psql_on "$1" -c 'insert into live_load values (1)'
    psql_on "$1" -c 'select pg_switch_wal()' >/dev/null
  done
  wait_for 60 "WAL waiting for the archive on $1" wal_waiting "$1"
}

# Waits until $1 is the primary with a standby, at most RECOVER_SECONDS after
# T0, then with the writer for its first write. Sets PROMOTED, and
# FIRST_WRITE with the writer.
wait_recovered() {
  local left=$((RECOVER_SECONDS - ($(now_ms) - T0) / 1000))
  ((left > 0)) || left=1
  wait_for "$left" "$1 as primary with a streaming standby" primary_with_standby "$1"
  PROMOTED=$(now_ms)
  if [[ $WRITER == on ]]; then
    wait_first_write "$1" "$RECOVER_SECONDS"
  fi
}

# The rows of one event, after its event row.
event_rows() {
  row "$1 primary, with a standby streaming" "$(secs "$PROMOTED")"
  if [[ $WRITER == on ]]; then
    row "first write on $1" "$(secs "$FIRST_WRITE")"
  fi
  row "store back, $HELD of 3 instances ready before" "$(secs "$STORE_BACK")"
  row "every instance ready and streaming" "$(secs "$BACK")"
}

# Keeps the store broken STORE_HOLD seconds more, then brings it back. Sets
# HELD, the ready instances just before, and STORE_BACK.
hold_and_restore() {
  sleep "$STORE_HOLD"
  HELD=$(cluster_field readyInstances)
  store_restore "$STORE_MODE"
  STORE_BACK=$(now_ms)
}

wait_for 600 "three ready instances, two streaming replicas" settled
start_client

summary "### store-$STORE_MODE, writer $WRITER"

# A primary node loss.
old=$(primary)
node=$(node_of "$old")
use_api_of "$(other_node "$node")"
break_store "$old"
T0=$(now_ms)
docker stop -t 0 "$node" >/dev/null
log "stopped $node, the node of primary $old"
wait_for "$RECOVER_SECONDS" "a primary other than $old" primary_not "$old"
new=$(primary)
log "new primary $new"
wait_recovered "$new"
sleep_until "$DOWN_SECONDS"
docker start "$node" >/dev/null
STARTED=$(now_ms)
log "started $node"
hold_and_restore
wait_back
summary ""
row "Seconds after the stop of $node, the node of primary $old, store ${STORE_MODE}s" ""
summary "|---|---|"
event_rows "$new"
row "$node started" "$(secs "$STARTED")"
for n in "${NODES[@]}"; do
  row "read port of $n" "$(read_port "$n")"
done
if [[ -n $FINAL_WRITE ]]; then
  row "one write, made after 600 s without every instance back; it ended the wait" "$(secs "$FINAL_WRITE")"
  FINAL_WRITE=''
fi
NODE_LOSS=$T0

# A switchover.
old=$(primary)
target=$(instances | awk -v p="$old" '$1 != p {print $1; exit}')
break_store "$old"
T0=$(now_ms)
k cnpg promote "$CLUSTER" "$target" -n "$NS" >/dev/null
log "promoting $target, primary was $old"
wait_recovered "$target"
hold_and_restore
wait_back
SWITCHOVER=$T0
# The writer's longest gap counts from the node loss.
T0=$NODE_LOSS
finish
T0=$SWITCHOVER
summary ""
row "Seconds after kubectl cnpg promote $target, primary was $old, store ${STORE_MODE}s" ""
summary "|---|---|"
event_rows "$target"
unset STARTED
common_rows
print_summary
