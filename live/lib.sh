# shellcheck shell=bash disable=SC2034
# Shared by live/up.sh and the scenarios. Source it.
#
# LIVE_WORK is the directory for the cluster's kubeconfigs, the client
# certificate, the tools and the logs; default /tmp/live.

LIVE_WORK=${LIVE_WORK:-/tmp/live}
LIVE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(dirname "$LIVE_DIR")
export PATH=$LIVE_WORK/bin:$PATH
# Never the caller's cluster.
export KUBECONFIG=$LIVE_WORK/kubeconfig

NS=databases
CLUSTER=pg
NETWORK=live
SUBNET=10.77.0.0/24
NODES=(k3s-1 k3s-2 k3s-3)
NODE_IPS=(10.77.0.11 10.77.0.12 10.77.0.13)
S3_IP=10.77.0.20

log() { echo "== $(date -u +%T) $*" >&2; }

fail() {
  echo "live: $*" >&2
  exit 1
}

# Runs "$@" every 2 s until it succeeds or $1 seconds have passed. Returns 1
# then, with the command's last error in POLL_ERR, also when an attempt that
# started in time succeeded only after the limit.
poll() {
  local end=$((SECONDS + $1))
  shift
  until POLL_ERR=$("$@" 2>&1 >/dev/null); do
    ((SECONDS < end)) || return 1
    sleep 2
  done
  if ((SECONDS > end)); then
    POLL_ERR="it held only after the limit"
    return 1
  fi
}

# Like poll, but fails after $1 seconds with a message that names $2, what it
# waited for, and the command's last error.
wait_for() {
  local limit=$1 what=$2
  shift 2
  log "waiting up to ${limit}s for $what"
  poll "$limit" "$@" || fail "gave up after ${limit}s waiting for $what${POLL_ERR:+: $POLL_ERR}"
}

# kubectl with a time limit on every call.
k() { timeout 30 kubectl "$@"; }

psql_on() {
  local pod=$1
  shift
  k exec -n "$NS" "$pod" -c postgres -- psql -U postgres -XqAt -v ON_ERROR_STOP=1 "$@"
}

cluster_field() { k get cluster "$CLUSTER" -n "$NS" -o jsonpath="{.status.$1}"; }
primary() { cluster_field currentPrimary; }
node_of() { k get pod "$1" -n "$NS" -o jsonpath='{.spec.nodeName}'; }
pod_ip() { k get pod "$1" -n "$NS" -o jsonpath='{.status.podIP}'; }

# The instance pods as "<pod> <node>" lines.
instances() {
  k get pods -n "$NS" -l "cnpg.io/cluster=$CLUSTER,cnpg.io/podRole=instance" --no-headers \
    -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName
}

node_ip() {
  local i
  for i in "${!NODES[@]}"; do
    if [[ ${NODES[$i]} == "$1" ]]; then
      echo "${NODE_IPS[$i]}"
      return
    fi
  done
  fail "no node $1"
}

# Sends kubectl to the API server of node $1, for when another node stops.
use_api_of() {
  export KUBECONFIG=$LIVE_WORK/kubeconfig.$1
}

# Every instance is ready, the cluster is healthy, and the primary streams to
# the other two. The primary is in pg_stat_replication of no other instance.
settled() {
  local p streaming
  p=$(primary)
  [[ $(cluster_field readyInstances) == 3 ]] || { echo "ready instances: $(cluster_field readyInstances)" >&2; return 1; }
  [[ $(cluster_field phase) == "Cluster in healthy state" ]] || { echo "phase: $(cluster_field phase)" >&2; return 1; }
  streaming=$(psql_on "$p" -c "select count(*) from pg_stat_replication where state = 'streaming'")
  [[ $streaming == 2 ]] || { echo "replicas streaming from $p: $streaming" >&2; return 1; }
}

# Instance $1 is the primary and out of recovery.
primary_is() {
  local p
  p=$(primary)
  [[ $p == "$1" ]] || { echo "primary: ${p:-none}" >&2; return 1; }
  [[ $(psql_on "$1" -c 'select pg_is_in_recovery()') == f ]] || { echo "$1 is in recovery" >&2; return 1; }
}

# Another instance than $1 is the primary and out of recovery.
primary_not() {
  local p
  p=$(primary)
  [[ -n $p && $p != "$1" ]] || { echo "primary: ${p:-none}" >&2; return 1; }
  primary_is "$p"
}

# The first node that is not $1.
other_node() {
  local n
  for n in "${NODES[@]}"; do
    if [[ $n != "$1" ]]; then
      echo "$n"
      return
    fi
  done
}

now_ms() { date +%s%3N; }

# Seconds from $T0 (ms) to the time $1 (ms), one decimal.
secs() { awk -v t="$1" -v t0="$T0" 'BEGIN {printf "%.1f", (t - t0) / 1000}'; }

# The database client: live/client, built by live/up.sh. Every scenario starts
# the readers; the writer runs when WRITER is on.
WRITER=${WRITER:-on}
case $WRITER in
  on | off) ;;
  *) fail "WRITER must be on or off, not $WRITER" ;;
esac
CERTS=$LIVE_WORK/certs
WRITE_LOG=$LIVE_WORK/write.log
READ_LOG=$LIVE_WORK/read.log
client_hosts() { local IFS=,; echo "${NODE_IPS[*]}"; }

# Starts the readers on every node's read port and, with WRITER on, the
# writer. Waits for the first acknowledged write.
start_client() {
  client read "$CERTS" "$(client_hosts)" >"$READ_LOG" 2>"$LIVE_WORK/read.err" &
  READER_PID=$!
  if [[ $WRITER == on ]]; then
    client write "$CERTS" "$(client_hosts)" >"$WRITE_LOG" 2>"$LIVE_WORK/write.err" &
    WRITER_PID=$!
    wait_for 120 "the first acknowledged write" grep -q ' ok ' "$WRITE_LOG"
  fi
}

# Stops the readers and the writer; each must still be running.
stop_client() {
  local pid
  for pid in ${WRITER_PID:-} "$READER_PID"; do
    kill -0 "$pid" 2>/dev/null || fail "the client $pid exited early: $(cat "$LIVE_WORK"/*.err)"
    kill -TERM "$pid"
    wait "$pid" || fail "the client $pid failed: $(cat "$LIVE_WORK"/*.err)"
  done
  T_END=$(now_ms)
}

# With WRITER off: one write through the rw LoadBalancer, which must succeed.
final_write() {
  client write-once "$CERTS" "$(client_hosts)" >>"$WRITE_LOG" || fail "the final write failed: $(tail -1 "$WRITE_LOG")"
  FINAL_WRITE=$(now_ms)
}

# The first acknowledged write after T0 on instance $1, as ms.
first_write_on() {
  local ip
  ip=$(pod_ip "$1")
  awk -v t0="$T0" -v ip="$ip" '$1 >= t0 && $3 == "ok" && $5 == ip {print $1; exit}' "$WRITE_LOG"
}

has_write_on() { [[ -n $(first_write_on "$1") ]]; }

# Waits until instance $1 has taken a write, at most until $2 seconds after
# T0, and sets FIRST_WRITE (ms). The wait runs 5 s longer, as a write is seen
# only at the next check of the log; the write's own time decides.
wait_first_write() {
  local left=$(($2 + 5 - ($(now_ms) - T0) / 1000))
  ((left > 0)) || left=1
  wait_for "$left" "a write on $1 within $2 s" has_write_on "$1"
  FIRST_WRITE=$(first_write_on "$1")
  ((FIRST_WRITE - T0 <= $2 * 1000)) || fail "the first write on $1 came $(secs "$FIRST_WRITE") s after the event, more than $2 s"
}

# Sleeps until $1 seconds after T0.
sleep_until() {
  local left
  left=$(awk -v t="$1" -v t0="$T0" -v now="$(now_ms)" 'BEGIN {l = t - (now - t0) / 1000; print (l > 0 ? l : 0)}')
  sleep "$left"
}

# Waits up to 10 min for every instance to be ready and streaming, and sets
# BACK (ms). Without the writer, a former primary that rewound onto an idle
# primary can wait for the primary's next WAL record, which an idle primary
# does not write (docs/samples.md). Then the final write must end the wait
# within 10 s, and FINAL_WRITE is set.
FINAL_WRITE=''
wait_back() {
  log "waiting up to 600s for every instance ready and streaming"
  if poll 600 settled; then
    BACK=$(now_ms)
    return
  fi
  [[ $WRITER == off ]] || fail "gave up after 600s waiting for every instance ready and streaming: $POLL_ERR"
  log "not every instance back after 600s without writes ($POLL_ERR); one write"
  final_write
  wait_for 10 "every instance ready and streaming after the final write" settled
  BACK=$(now_ms)
  ((BACK - FINAL_WRITE <= 10000)) || fail "every instance was back only $(((BACK - FINAL_WRITE) / 1000)) s after the final write, more than 10 s"
}

# The last read probe of every node answered.
reads_back() {
  local n ip last
  for n in "${NODES[@]}"; do
    ip=$(node_ip "$n")
    last=$(awk -v ip="$ip" '$2 == ip {r = $3} END {print r}' "$READ_LOG")
    [[ $last == ok ]] || { echo "the read port of $n does not answer" >&2; return 1; }
  done
}

# The longest time without an acknowledged write between T0 and T_END, as ms.
longest_write_gap() {
  awk -v t0="$T0" -v end="$T_END" '
    $3 == "ok" && $1 >= t0 && $1 <= end {if ($1 - last > gap) gap = $1 - last; last = $1}
    BEGIN {last = t0}
    END {if (end - last > gap) gap = end - last; print gap}' "$WRITE_LOG"
}

# Every acknowledged commit is in live_writes on the primary. Prints how many.
check_commits() {
  local p acked present lost
  p=$(primary)
  acked=$LIVE_WORK/acked
  present=$LIVE_WORK/present
  awk '$3 == "ok" {print $4}' "$WRITE_LOG" | sort >"$acked"
  psql_on "$p" -d orders -c 'select n from live_writes' | sort >"$present"
  lost=$(comm -23 "$acked" "$present" | wc -l)
  if ((lost > 0)); then
    fail "$lost of $(wc -l <"$acked") acknowledged commits are not on $p, the first: $(comm -23 "$acked" "$present" | head -5 | paste -sd ' ')"
  fi
  wc -l <"$acked"
}

# When the read port of node $1 was down after T0: "never down", or the
# first failure and the first answer after the last failure.
read_port() {
  local ip
  ip=$(node_ip "$1")
  awk -v t0="$T0" -v ip="$ip" '
    $1 < t0 || $2 != ip {next}
    $3 == "fail" {if (!down) down = $1; back = 0}
    $3 == "ok" && down && !back {back = $1}
    END {
      if (!down) print "never down"
      else if (!back) printf "down from %.1f, not back\n", (down - t0) / 1000
      else printf "down from %.1f, back at %.1f\n", (down - t0) / 1000, (back - t0) / 1000
    }' "$READ_LOG"
}

# Ends a scenario: waits until every node's read port answers, stops the
# client and, without the writer, makes the final write. Checks that every acknowledged commit is on the primary and, with the
# writer, that no time without an acknowledged write since T0 was longer than
# 180 s. Sets COMMITS and GAP (ms).
finish() {
  wait_for 60 "the read port of every node" reads_back
  stop_client
  if [[ $WRITER == off && -z $FINAL_WRITE ]]; then
    final_write
  fi
  COMMITS=$(check_commits)
  GAP=''
  if [[ $WRITER == on ]]; then
    GAP=$(longest_write_gap)
    ((GAP <= 180000)) || fail "no acknowledged write for $((GAP / 1000)) s, more than 180 s"
  fi
}

# Adds a line to the summary on stdout and in the job summary.
SUMMARY=()
summary() { SUMMARY+=("$1"); }
row() { summary "| $1 | $2 |"; }

# The rows every scenario ends with.
common_rows() {
  local n
  for n in "${NODES[@]}"; do
    row "read port of $n" "$(read_port "$n")"
  done
  if [[ -n ${STARTED:-} ]]; then
    row "every instance ready and streaming" "$(secs "$BACK"), $(awk -v b="$BACK" -v s="$STARTED" 'BEGIN {printf "%.1f", (b - s) / 1000}') after the start"
  else
    row "every instance ready and streaming" "$(secs "$BACK")"
  fi
  if [[ $WRITER == on ]]; then
    row "longest time without an acknowledged write" "$(awk -v g="$GAP" 'BEGIN {printf "%.1f", g / 1000}')"
  elif ((FINAL_WRITE < BACK)); then
    row "final write" "$(secs "$FINAL_WRITE"), made after 600 s without every instance back; it ended the wait"
  else
    row "final write" "$(secs "$FINAL_WRITE")"
  fi
  row "acknowledged commits, all on the primary" "$COMMITS"
}
print_summary() {
  local line
  for line in "${SUMMARY[@]}"; do
    echo "$line"
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then echo "$line" >>"$GITHUB_STEP_SUMMARY"; fi
  done
}
