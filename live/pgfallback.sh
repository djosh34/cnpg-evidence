# shellcheck shell=bash
# pgfallback, the Go package of this repository, against the cluster from the
# runner, as an application outside the cluster uses it.
# live/scenarios/pgfallback-*.sh source this after setting EVENT to drain,
# primary-node-loss or replica-node-loss.
#
# The program live/pgfallback, copied out of the checkout, gets the package
# with go get github.com/djosh34/cnpg-evidence/pgfallback@<the checked out
# commit>. It runs on the runner against the node addresses: rw on 5432, read
# on 5433, verify-full against the node names, which live/values.yaml adds to
# the server certificate. It uses pgxpool and GORM at the same time and
# connects to each rw address alone (see live/pgfallback/main.go). Then the
# event:
#
#   drain: kubectl drain of the primary's node, which moves the primary, and
#     kubectl uncordon once the drain is done.
#   primary-node-loss: the primary's node stops with docker stop -t 0 and
#     starts again DOWN_SECONDS later.
#   replica-node-loss: a replica's node, the same way. The primary must stay.
#
# Once every instance is ready and streaming and every read port answers,
# the program runs PGF_AFTER seconds more. It must end on rw, no query or
# write may land on a read address that rw should have taken, and every
# write it got acknowledged must be on the primary. The program runs in both
# modes, since its writes are what this tests; WRITER only starts or leaves
# out live/client's writer.

DOWN_SECONDS=120
PGF_AFTER=30
PGF_DIR=$LIVE_WORK/pgfallback
PGF_LOG=$LIVE_WORK/pgfallback.log
PGF_ERR=$LIVE_WORK/pgfallback.err
PGF_MODULE=github.com/djosh34/cnpg-evidence

# The node names and IPs as the program takes them.
pgf_nodes() {
  local i list=()
  for i in "${!NODES[@]}"; do
    list+=("${NODES[$i]}=${NODE_IPS[$i]}")
  done
  local IFS=,
  echo "${list[*]}"
}

# Builds the program outside the checkout, with the package at the checked
# out commit, through the Go module proxy. Sets PGF_VERSION.
build_pgfallback() {
  local sha
  sha=$(git -C "$REPO" rev-parse HEAD)
  rm -rf "$PGF_DIR"
  mkdir -p "$PGF_DIR"
  cp "$LIVE_DIR"/pgfallback/{go.mod,go.sum,main.go,report.go} "$PGF_DIR"
  (
    cd "$PGF_DIR"
    go mod edit -dropreplace="$PGF_MODULE" -droprequire="$PGF_MODULE"
    timeout 300 go get "$PGF_MODULE/pgfallback@$sha"
    go build -o "$LIVE_WORK/bin/pgfallback-live" .
  ) || fail "building live/pgfallback with $PGF_MODULE/pgfallback@$sha failed"
  PGF_VERSION=$(cd "$PGF_DIR" && go list -m -f '{{.Version}}' "$PGF_MODULE")
  [[ $PGF_VERSION == *-"${sha:0:12}" ]] || fail "go get gave $PGF_MODULE $PGF_VERSION, not commit $sha"
  log "pgfallback from $PGF_MODULE $PGF_VERSION"
}

# The program has run a query and a write through pgx and GORM, and a
# connect to every rw address alone.
pgf_working() {
  local c w n
  kill -0 "$PGF_PID" 2>/dev/null || { echo "pgfallback-live exited: $(cat "$PGF_ERR")" >&2; return 1; }
  for c in pgx gorm; do
    for w in query write; do
      grep -q "^[0-9]* [0-9]* $c $w [^ ]* ok" "$PGF_LOG" || { echo "no $c $w yet" >&2; return 1; }
    done
  done
  for n in "${NODES[@]}"; do
    grep -q "^[0-9]* [0-9]* rw connect $n:5432 ok" "$PGF_LOG" || { echo "no connect to $n:5432 yet" >&2; return 1; }
  done
}

start_pgfallback() {
  pgfallback-live run "$CERTS" "$(pgf_nodes)" >"$PGF_LOG" 2>"$PGF_ERR" &
  PGF_PID=$!
  wait_for 120 "pgfallback's first queries, writes and connects" pgf_working
}

stop_pgfallback() {
  kill -0 "$PGF_PID" 2>/dev/null || fail "pgfallback-live exited early: $(cat "$PGF_ERR")"
  kill -TERM "$PGF_PID"
  wait "$PGF_PID" || fail "pgfallback-live failed: $(cat "$PGF_ERR")"
}

# Every write the program got acknowledged is in pgfallback_writes on the
# primary. Prints how many.
pgf_check_commits() {
  local p acked present lost
  p=$(primary)
  acked=$LIVE_WORK/pgfallback.acked
  present=$LIVE_WORK/pgfallback.present
  awk '$4 == "write" && $6 == "ok" {print $3, $7}' "$PGF_LOG" | sort >"$acked"
  psql_on "$p" -d orders -c "select client || ' ' || n from pgfallback_writes" | sort >"$present"
  lost=$(comm -23 "$acked" "$present" | wc -l)
  if ((lost > 0)); then
    fail "$lost of $(wc -l <"$acked") writes pgfallback got acknowledged are not on $p, the first: $(comm -23 "$acked" "$present" | head -5 | paste -sd ' ')"
  fi
  wc -l <"$acked"
}

wait_for 600 "three ready instances, two streaming replicas" settled
build_pgfallback
first=$(primary)
case $EVENT in
  drain | primary-node-loss)
    node=$(node_of "$first")
    what="primary $first"
    ;;
  replica-node-loss)
    replica=$(instances | awk -v p="$first" '$1 != p {print $1; exit}')
    node=$(node_of "$replica")
    what="replica $replica"
    ;;
  *) fail "EVENT must be drain, primary-node-loss or replica-node-loss, not $EVENT" ;;
esac
use_api_of "$(other_node "$node")"
start_monitoring "$(other_node "$node")"
start_client
start_pgfallback

T0=$(now_ms)
case $EVENT in
  drain)
    log "draining $node, the node of $what"
    timeout 630 kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=600s >&2 ||
      fail "kubectl drain $node did not finish within 600s"
    DRAINED=$(now_ms)
    wait_for 60 "a primary other than $first" primary_not "$first"
    k uncordon "$node" >/dev/null
    STARTED=$(now_ms)
    log "uncordoned $node"
    ;;
  primary-node-loss)
    docker stop -t 0 "$node" >/dev/null
    log "stopped $node, the node of $what"
    wait_for 600 "a primary other than $first" primary_not "$first"
    PROMOTED=$(now_ms)
    sleep_until "$DOWN_SECONDS"
    docker start "$node" >/dev/null
    STARTED=$(now_ms)
    log "started $node"
    ;;
  replica-node-loss)
    docker stop -t 0 "$node" >/dev/null
    log "stopped $node, the node of $what"
    sleep_until "$DOWN_SECONDS"
    primary_is "$first" || fail "the primary moved away from $first while $node was down"
    docker start "$node" >/dev/null
    STARTED=$(now_ms)
    log "started $node"
    ;;
esac
wait_back
wait_for 60 "the read port of every node" reads_back
sleep "$PGF_AFTER"
stop_pgfallback
PGF_COMMITS=$(pgf_check_commits)
status=0
pgf_report=$(pgfallback-live report "$PGF_LOG" "$T0" "$(pgf_nodes)") || status=$?
((status <= 1)) || fail "pgfallback-live report failed with exit code $status"
if [[ $EVENT == replica-node-loss ]]; then
  primary_is "$first" || fail "the primary moved away from $first after $node started"
fi
finish

summary "### pgfallback-$EVENT, writer $WRITER"
summary ""
summary "pgfallback from \`$PGF_MODULE $PGF_VERSION\`; the primary at the start was $first."
summary ""
case $EVENT in
  drain) row "Seconds after kubectl drain $node, the node of $what" "" ;;
  *) row "Seconds after the stop of $node, the node of $what" "" ;;
esac
summary "|---|---|"
case $EVENT in
  drain)
    row "drain done, $(primary) primary" "$(secs "$DRAINED")"
    row "$node uncordoned" "$(secs "$STARTED")"
    ;;
  primary-node-loss)
    row "$(primary) primary" "$(secs "$PROMOTED")"
    row "$node started" "$(secs "$STARTED")"
    ;;
  replica-node-loss) row "$node started, $first still primary" "$(secs "$STARTED")" ;;
esac
common_rows
row "writes pgfallback got acknowledged, all on the primary" "$PGF_COMMITS"
summary ""
while IFS= read -r line; do
  summary "$line"
done <<<"$pgf_report"
print_summary
((status == 0)) || fail "pgfallback did what it must not; see the summary"
