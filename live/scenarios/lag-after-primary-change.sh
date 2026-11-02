#!/usr/bin/env bash
# Replica lag after a primary change. CNPG's cnpg_pg_replication_lag reports
# minutes on a caught-up replica for up to 5 min after its PostgreSQL
# restarts, until the primary writes WAL; the chart's cnpg_replica_lag_seconds
# must not.
#
# 1. kubectl cnpg promote to a replica.
# 2. kubectl cnpg fencing on the new primary, and fencing off 30 s later.
#
# After each, once every instance is ready and streaming, the lag of every
# replica must stay under 1 s for 330 s, longer than the 5 min the false lag
# lasted. CNPGReplicaLag must not fire. The summary gives the most that
# cnpg_pg_replication_lag reported in the same time.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

WATCH_SECONDS=330
FENCE_SECONDS=30

# The most query $1 reported per pod in the last WATCH_SECONDS, as
# "<pod> <value>" lines.
most_per_pod() {
  local result
  result=$(prom_query "max by (pod) (max_over_time($1{cluster=\"$CLUSTER\"}[${WATCH_SECONDS}s]))") || fail "Prometheus did not answer"
  jq -r '.data.result[] | "\(.metric.pod) \(.value[1])"' <<<"$result" | sort
}

# Watches the replicas' lag for WATCH_SECONDS from now. Adds the rows.
watch_lag() {
  local lag old
  sleep "$WATCH_SECONDS"
  lag=$(most_per_pod cnpg_replica_lag_seconds)
  old=$(most_per_pod cnpg_pg_replication_lag)
  [[ $(wc -l <<<"$lag") == 2 ]] || fail "cnpg_replica_lag_seconds of two replicas expected, got: $(paste -sd ';' <<<"$lag")"
  awk '$2 >= 1 {bad = 1} END {exit bad}' <<<"$lag" || fail "a replica reported 1 s of lag or more: $(paste -sd ';' <<<"$lag")"
  row "most cnpg_replica_lag_seconds of each replica in the $WATCH_SECONDS s after" "$(paste -sd ';' <<<"$lag" | sed 's/;/, /g')"
  row "most cnpg_pg_replication_lag in the same time" "$(paste -sd ';' <<<"$old" | sed 's/;/, /g')"
}

wait_for 600 "three ready instances, two streaming replicas" settled
old=$(primary)
target=$(instances | awk -v p="$old" '$1 != p {print $1; exit}')
start_monitoring "${NODES[0]}"
start_client

summary "### lag-after-primary-change, writer $WRITER"
summary ""
row "Seconds after kubectl cnpg promote $target, primary was $old" ""
summary "|---|---|"
T0=$(now_ms)
k cnpg promote "$CLUSTER" "$target" -n "$NS" >/dev/null
wait_for 300 "$target as primary" primary_is "$target"
row "$target primary" "$(secs "$(now_ms)")"
wait_back
row "every instance ready and streaming" "$(secs "$BACK")"
watch_lag

summary ""
row "Seconds after kubectl cnpg fencing on $target" ""
summary "|---|---|"
T0=$(now_ms)
k cnpg fencing on "$CLUSTER" "$target" -n "$NS" >/dev/null
sleep_until "$FENCE_SECONDS"
k cnpg fencing off "$CLUSTER" "$target" -n "$NS" >/dev/null
row "kubectl cnpg fencing off $target" "$(secs "$(now_ms)")"
wait_back
primary_is "$target" || fail "the primary moved away from $target"
row "every instance ready and streaming" "$(secs "$BACK")"
watch_lag
finish
common_rows
print_summary
