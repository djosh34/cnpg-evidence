#!/usr/bin/env bash
# The alerts for a replica that falls behind and for commits that wait.
#
# 1. Replay pauses on a replica, and the primary commits a row the replica
#    then does not replay. CNPGReplicaLag must fire for it within 5 min, the
#    rule's 15 s and 2 min plus scrapes and evaluations, and reach
#    Alertmanager. Replay resumes; the alert must resolve within 2 min.
# 2. On the primary, one transaction runs a 15 s statement and then commits,
#    which waits only a moment for its standby. CNPGWritesBlocked must not
#    fire.
# 3. Replay pauses on both replicas, so a commit on the primary waits for a
#    standby to apply it, as when no synchronous standby confirms. One
#    commit is made that waits. CNPGWritesBlocked must fire for the primary
#    within 2 min and reach Alertmanager. Replay resumes; the waiting commit
#    must succeed and the alert resolve within 2 min.
#
# Without the writer, these commits are the only writes.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

replay() { psql_on "$2" -c "select pg_wal_replay_$1()" >/dev/null; }

wait_for 600 "three ready instances, two streaming replicas" settled
p=$(primary)
replica=$(instances | awk -v p="$p" '$1 != p {print $1; exit}')
other=$(instances | awk -v p="$p" -v r="$replica" '$1 != p && $1 != r {print $1; exit}')
start_monitoring "${NODES[0]}"
expect_alert CNPGReplicaLag "$replica"
expect_alert CNPGWritesBlocked "$p"
start_client
psql_on "$p" -c 'create table if not exists live_stall (n int)'

T0=$(now_ms)
replay pause "$replica"
psql_on "$p" -c 'insert into live_stall values (1)'
log "replay paused on $replica"
wait_for 300 "CNPGReplicaLag firing for $replica" alert_firing CNPGReplicaLag "$replica"
LAG_FIRED=$(now_ms)
wait_for 60 "Alertmanager sending CNPGReplicaLag for $replica" am_alert_is CNPGReplicaLag "$replica" active
replay resume "$replica"
LAG_RESUMED=$(now_ms)
wait_for 120 "CNPGReplicaLag resolved for $replica" alert_resolved CNPGReplicaLag "$replica"
LAG_RESOLVED=$(now_ms)

LONG=$(now_ms)
psql_on "$p" -c 'begin' -c 'select pg_sleep(15)' -c 'insert into live_stall values (2)' -c 'commit' >/dev/null
# Two more evaluations, so a wait the rules saw would show.
sleep 15
fired=$(prom_query "max_over_time(ALERTS{alertname=\"CNPGWritesBlocked\", alertstate=\"firing\"}[$((($(now_ms) - LONG) / 1000))s])") ||
  fail "Prometheus did not answer"
[[ $(jq '.data.result | length' <<<"$fired") == 0 ]] || fail "CNPGWritesBlocked fired for a 15 s statement whose commit waited only a moment"

replay pause "$replica"
replay pause "$other"
STALLED=$(now_ms)
# The waiting commit, with a limit of its own: the scripts' kubectl calls
# have 30 s.
timeout 300 kubectl exec -n "$NS" "$p" -c postgres -- psql -U postgres -XqAt -v ON_ERROR_STOP=1 \
  -c 'insert into live_stall values (3)' >/dev/null &
stall_pid=$!
log "replay paused on $replica and $other, a commit waits"
wait_for 120 "CNPGWritesBlocked firing for $p" alert_firing CNPGWritesBlocked "$p"
STALL_FIRED=$(now_ms)
wait_for 60 "Alertmanager sending CNPGWritesBlocked for $p" am_alert_is CNPGWritesBlocked "$p" active
replay resume "$replica"
replay resume "$other"
STALL_RESUMED=$(now_ms)
wait "$stall_pid" || fail "the commit that waited failed"
wait_for 120 "CNPGWritesBlocked resolved for $p" alert_resolved CNPGWritesBlocked "$p"
STALL_RESOLVED=$(now_ms)

wait_back
finish

summary "### lag-and-stall, writer $WRITER"
summary ""
row "Seconds after replay paused on $replica" ""
summary "|---|---|"
row "CNPGReplicaLag fires for $replica, and reaches Alertmanager" "$(secs "$LAG_FIRED")"
row "replay resumed" "$(secs "$LAG_RESUMED")"
row "CNPGReplicaLag resolved" "$(secs "$LAG_RESOLVED")"
row "a 15 s statement and its commit, from" "$(secs "$LONG"); CNPGWritesBlocked did not fire"
row "replay paused on $replica and $other, a commit on $p waits" "$(secs "$STALLED")"
row "CNPGWritesBlocked fires for $p, and reaches Alertmanager" "$(secs "$STALL_FIRED")"
row "replay resumed, the commit went through" "$(secs "$STALL_RESUMED")"
row "CNPGWritesBlocked resolved" "$(secs "$STALL_RESOLVED")"
common_rows
print_summary
