#!/usr/bin/env bash
# A rollout, then a switchover, with the writer's pooled session open. The
# rollout changes shared_buffers on the Cluster, a parameter that needs a
# restart: CNPG restarts the replicas, then restarts the primary in place
# (primaryUpdateMethod: restart). PostgreSQL then starts with CNPG's own
# pg_ident lines only, and the chart's lines come back at the instance's next
# reconcile (docs/samples.md). The switchover is kubectl cnpg promote to a
# replica. After the rollout, every instance must be ready and streaming with
# the chart's pg_ident lines within 10 min, and the primary must not have
# moved; after the switchover, every instance must be ready and streaming
# within 10 min. With the writer, writes may stop for at most 30 s at any
# time, and the summary gives the longest stop in each.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

SHARED_BUFFERS=160MB
STOP_LIMIT=30
WRITE_GAP_LIMIT=$STOP_LIMIT

# Every instance runs with the new shared_buffers and no pending restart, has
# the pg_ident lines in $WANT, and the cluster has settled.
rolled_out() {
  local pods pod value pending
  pods=$(instance_pods) || return 1
  for pod in $pods; do
    value=$(psql_on "$pod" -c 'show shared_buffers')
    [[ $value == "$SHARED_BUFFERS" ]] || { echo "shared_buffers on $pod: $value" >&2; return 1; }
    pending=$(psql_on "$pod" -c 'select count(*) from pg_settings where pending_restart')
    [[ $pending == 0 ]] || { echo "$pod has $pending settings pending a restart" >&2; return 1; }
  done
  ident_everywhere || return 1
  settled
}

# Fails when writes stopped for more than STOP_LIMIT s from $2 to $3 (ms) and
# prints the longest stop, for the event $1.
write_stop() {
  local gap
  gap=$(longest_write_gap "$2" "$3")
  ((gap <= STOP_LIMIT * 1000)) || fail "the $1 stopped writes for $((gap / 1000)) s, more than $STOP_LIMIT s"
  awk -v g="$gap" 'BEGIN {printf "%.1f", g / 1000}'
}

wait_for 600 "three ready instances, two streaming replicas" settled
old=$(primary)
want_ident "$old"
start_monitoring "${NODES[0]}"
start_client

T0=$(now_ms)
k patch cluster "$CLUSTER" -n "$NS" --type merge \
  -p "{\"spec\":{\"postgresql\":{\"parameters\":{\"shared_buffers\":\"$SHARED_BUFFERS\"}}}}" >/dev/null
log "shared_buffers set to $SHARED_BUFFERS, primary was $old"
wait_for 600 "every instance on shared_buffers $SHARED_BUFFERS with the chart's pg_ident lines, ready and streaming" rolled_out
ROLLED=$(now_ms)
rolled=$(primary)
[[ $rolled == "$old" ]] || fail "the rollout moved the primary from $old to $rolled instead of restarting it in place"
log "rollout done, primary $rolled"
if [[ $WRITER == on ]]; then
  wait_first_write "$rolled" "$STOP_LIMIT" "$ROLLED"
fi

target=$(instances | awk -v p="$rolled" '$1 != p {print $1; exit}')
SWITCH=$(now_ms)
k cnpg promote "$CLUSTER" "$target" -n "$NS" >/dev/null
log "promoting $target, primary was $rolled"
wait_for 300 "$target as primary" primary_is "$target"
promoted=$(now_ms)
if [[ $WRITER == on ]]; then
  wait_first_write "$target" "$STOP_LIMIT" "$promoted"
fi
wait_back
if [[ $WRITER == on ]]; then
  ROLLOUT_STOP=$(write_stop rollout "$T0" "$SWITCH")
  SWITCH_STOP=$(write_stop switchover "$SWITCH" "$BACK")
fi
finish

summary "### rollout, writer $WRITER"
summary ""
row "Seconds after shared_buffers was set to $SHARED_BUFFERS, primary was $old" ""
summary "|---|---|"
row "rollout done: every instance restarted, ready and streaming with the chart's pg_ident lines, $rolled still primary" "$(secs "$ROLLED")"
if [[ $WRITER == on ]]; then
  row "longest time without an acknowledged write in the rollout" "$ROLLOUT_STOP"
fi
row "kubectl cnpg promote $target" "$(secs "$SWITCH")"
row "$target primary" "$(secs "$promoted")"
if [[ $WRITER == on ]]; then
  row "longest time without an acknowledged write in the switchover" "$SWITCH_STOP"
fi
common_rows
print_summary
