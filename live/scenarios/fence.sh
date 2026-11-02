#!/usr/bin/env bash
# The primary is fenced with kubectl cnpg fencing on, which stops its
# PostgreSQL, and unfenced 30 s later. PostgreSQL starts again with CNPG's
# own pg_ident lines only, and the chart's lines come back at the instance's
# next reconcile (docs/samples.md). Until then certificate logins to it fail,
# replication included, so writes wait too. The chart's lines must come back
# and both replicas must stream from it again by themselves within 10 min of
# the unfence, and the primary must not move. With the writer, writes may
# stop for the 30 s of the fence plus those 10 min. The job summary gives the
# times.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

FENCE_SECONDS=30
BACK_LIMIT=600
WRITE_GAP_LIMIT=$((FENCE_SECONDS + BACK_LIMIT))

ident_of() {
  psql_on "$1" -c 'select map_name, sys_name, pg_username, error from pg_ident_file_mappings order by 1, 2, 3'
}

# Instance $1 has the pg_ident lines in $WANT.
ident_back() {
  local got
  got=$(ident_of "$1") || return 1
  [[ $got == "$WANT" ]] || { echo "pg_ident of $1: $(paste -sd ' ' <<<"$got")" >&2; return 1; }
}

# psql on instance $1 cannot connect: it exits with 2, which kubectl exec
# passes on. Its own errors exit with 1.
stopped() {
  local status=0
  psql_on "$1" -c 'select 1' >/dev/null 2>&1 || status=$?
  [[ $status == 2 ]] || { echo "psql on $1 exited with $status, not 2 for no connection" >&2; return 1; }
}

wait_for 600 "three ready instances, two streaming replicas" settled
p=$(primary)
replica=$(instances | awk -v p="$p" '$1 != p {print $1; exit}')
WANT=$(ident_of "$replica")
ident_back "$p" || fail "$p and $replica have different pg_ident lines before the fence"
start_monitoring "${NODES[0]}"
start_client

T0=$(now_ms)
k cnpg fencing on "$CLUSTER" "$p" -n "$NS" >/dev/null
log "fenced primary $p"
wait_for 120 "PostgreSQL on $p stopped" stopped "$p"
STOPPED=$(now_ms)
sleep_until "$FENCE_SECONDS"
k cnpg fencing off "$CLUSTER" "$p" -n "$NS" >/dev/null
UNFENCED=$(now_ms)
log "unfenced $p"
wait_for "$BACK_LIMIT" "the chart's pg_ident lines on $p" ident_back "$p"
IDENT=$(now_ms)
wait_back
((BACK - UNFENCED <= BACK_LIMIT * 1000)) ||
  fail "every instance was ready and streaming only $(((BACK - UNFENCED) / 1000)) s after the unfence, more than $BACK_LIMIT s"
primary_is "$p" || fail "the primary moved away from $p"
finish

summary "### fence, writer $WRITER"
summary ""
row "Seconds after kubectl cnpg fencing on $p, the primary" ""
summary "|---|---|"
row "PostgreSQL on $p stopped" "$(secs "$STOPPED")"
row "kubectl cnpg fencing off $p" "$(secs "$UNFENCED")"
row "the chart's pg_ident lines back on $p" "$(secs "$IDENT"), $(awk -v i="$IDENT" -v u="$UNFENCED" 'BEGIN {printf "%.1f", (i - u) / 1000}') after the unfence"
common_rows
print_summary
