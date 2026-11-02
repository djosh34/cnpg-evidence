#!/usr/bin/env bash
# A replica's node is lost while the primary writes at least 1.2 GB of WAL,
# far more than CNPG's default wal_keep_size of 512 MB. Then the object store
# refuses connections and the node starts again. The replica must stream
# again and catch up with the primary by itself within 10 min, from the WAL
# the primary keeps (wal_keep_size), without the store. How far behind it was
# when its pod turned ready, which opens its node's read port, is recorded,
# not checked. Then the store comes back.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

LOAD_MB=1229
DOWN_SECONDS=360  # the node stays down at least this long

pod_ready() {
  [[ $(k get pod "$1" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') == True ]]
}

# MB that instance $1 has not replayed yet of the primary's WAL.
behind_mb() {
  local lsn
  lsn=$(psql_on "$(primary)" -c 'select pg_current_wal_lsn()')
  psql_on "$1" -c "select round((pg_wal_lsn_diff('$lsn', pg_last_wal_replay_lsn()) / 1048576)::numeric, 1)"
}

# Instance $1 streams and has replayed the primary's WAL up to where it was
# a moment ago.
caught_up() {
  local lsn
  lsn=$(psql_on "$(primary)" -c 'select pg_current_wal_lsn()')
  [[ $(psql_on "$1" -c "select status = 'streaming' and pg_last_wal_replay_lsn() >= '$lsn' from pg_stat_wal_receiver") == t ]] ||
    { echo "$1 does not stream or has not replayed up to $lsn" >&2; return 1; }
}

wait_for 600 "three ready instances, two streaming replicas" settled
p=$(primary)
replica=$(instances | awk -v p="$p" '$1 != p {print $1; exit}')
node=$(node_of "$replica")
use_api_of "$(other_node "$node")"
start_client

T0=$(now_ms)
docker stop -t 0 "$node" >/dev/null
log "stopped $node, the node of replica $replica"
written=$(write_wal "$p" "$LOAD_MB")
LOADED=$(now_ms)
log "wrote $written MB of WAL on $p"
sleep_until "$DOWN_SECONDS"
store_break refuse
docker start "$node" >/dev/null
STARTED=$(now_ms)
log "started $node"

# Until the replica has caught up and its pod has turned ready, with how far
# behind it was then. A failed read is tried again at the next round.
log "waiting up to 600s for $replica to catch up"
end=$((SECONDS + 600))
OPEN_LAG=''
why="$replica not ready"
while :; do
  if [[ -z $OPEN_LAG ]] && pod_ready "$replica" 2>/dev/null && lag=$(behind_mb "$replica" 2>/dev/null); then
    OPEN_AT=$(now_ms)
    OPEN_LAG=$lag
    log "$replica ready, $OPEN_LAG MB behind"
  fi
  if [[ -n $OPEN_LAG ]] && why=$(caught_up "$replica" 2>&1); then
    break
  fi
  ((SECONDS < end)) || fail "gave up after 600s waiting for $replica to turn ready and catch up: $why"
  sleep 2
done
CAUGHT_UP=$(now_ms)
log "$replica caught up"
store_restore refuse
STORE_BACK=$(now_ms)
wait_back
finish

summary "### replica-down-long, writer $WRITER"
summary ""
row "Seconds after the stop of $node, the node of replica $replica" ""
summary "|---|---|"
row "$written MB of WAL written on $p" "$(secs "$LOADED")"
row "store refuses, $node started" "$(secs "$STARTED")"
row "$replica ready, $OPEN_LAG MB behind" "$(secs "$OPEN_AT")"
row "$replica streams and has caught up, store still refusing" "$(secs "$CAUGHT_UP")"
row "store back" "$(secs "$STORE_BACK")"
common_rows
print_summary
