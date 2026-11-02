# shellcheck shell=bash disable=SC2034
# Shared by live/up.sh, live/host-check.sh and the scenarios. Source it.
#
# LIVE_WORK is the directory for the cluster's kubeconfigs, the client
# certificate, the tools and the logs; default /tmp/live.

LIVE_WORK=${LIVE_WORK:-/tmp/live}
LIVE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(dirname "$LIVE_DIR")
export PATH=$LIVE_WORK/bin:$PATH
# Never the caller's cluster.
export KUBECONFIG=$LIVE_WORK/kubeconfig

K3S_IMAGE=rancher/k3s@sha256:ada5ff2e138120efe877f76d514dedda65b304122112b982eab532732c028c89  # v1.33.13+k3s2

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

# The metrics page of instance $1, read from 9187 through kubectl
# port-forward, so nothing runs in the instance image. The certificate is
# not checked here; evidence.sh checks the port's TLS.
metrics_of() {
  local pod=$1 forward pid line page
  exec {forward}< <(exec kubectl port-forward -n "$NS" "pod/$pod" :9187 2>&1)
  pid=$!
  if ! read -r -t 30 line <&"$forward" ||
    [[ ! $line =~ ^Forwarding\ from\ 127\.0\.0\.1:([0-9]+)\ -\>\ 9187$ ]]; then
    kill "$pid" 2>/dev/null || true # it may have ended with the error read here
    fail "port-forward to $pod:9187 did not start: ${line:-no output in 30 s}"
  fi
  if ! page=$(curl -fsSk --max-time 10 "https://127.0.0.1:${BASH_REMATCH[1]}/metrics"); then
    kill "$pid" 2>/dev/null || true # it may have ended too; the failed read is the error
    fail "no metrics from $pod:9187"
  fi
  kill "$pid" || fail "port-forward to $pod:9187 ended early"
  exec {forward}<&-
  echo "$page"
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

# The instance pod names, one per line. Fails when the listing fails or
# finds none, so a loop over them cannot pass by checking nothing.
instance_pods() {
  local list
  list=$(instances) || return 1
  [[ -n $list ]] || { echo "no instance pods of $CLUSTER" >&2; return 1; }
  awk '{print $1}' <<<"$list"
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

# The first acknowledged write on instance $1 at or after $2 (ms, default
# T0), as ms.
first_write_on() {
  local ip
  ip=$(pod_ip "$1")
  awk -v t0="${2:-$T0}" -v ip="$ip" '$1 >= t0 && $3 == "ok" && $5 == ip {print $1; exit}' "$WRITE_LOG"
}

has_write_on() { [[ -n $(first_write_on "$@") ]]; }

# Waits until instance $1 has taken a write, at most until $2 seconds after
# $3 (ms, default T0), and sets FIRST_WRITE (ms). The wait runs 5 s longer,
# as a write is seen only at the next check of the log; the write's own time
# decides.
wait_first_write() {
  local since=${3:-$T0}
  local left=$(($2 + 5 - ($(now_ms) - since) / 1000))
  ((left > 0)) || left=1
  wait_for "$left" "a write on $1 within $2 s" has_write_on "$1" "$since"
  FIRST_WRITE=$(first_write_on "$1" "$since")
  ((FIRST_WRITE - since <= $2 * 1000)) || fail "the first write on $1 came $(((FIRST_WRITE - since) / 1000)) s after the event, more than $2 s"
}

# The number of acknowledged writes from $1 to $2 (ms).
writes_between() {
  awk -v from="$1" -v to="$2" '$3 == "ok" && $1 >= from && $1 <= to {n++} END {print n + 0}' "$WRITE_LOG"
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

# The longest time without an acknowledged write from $1 to $2 (ms), as ms.
longest_write_gap() {
  awk -v t0="$1" -v end="$2" '
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

# The read probes of node $1 from $2 to $3 (ms) as "<ok> <failed>".
reads_between() {
  local ip
  ip=$(node_ip "$1")
  awk -v ip="$ip" -v from="$2" -v to="$3" '
    $2 == ip && $1 >= from && $1 <= to {if ($3 == "ok") ok++; else failed++}
    END {print ok + 0, failed + 0}' "$READ_LOG"
}

# Ends a scenario: waits until every node's read port answers, stops the
# client and, without the writer, makes the final write. Checks that every
# acknowledged commit is on the primary and, with the writer, that no time
# without an acknowledged write since T0 was longer than WRITE_GAP_LIMIT
# seconds, 180 unless the scenario sets it. Then checks the alerts
# (check_alerts) and the dashboard's queries (check_dashboard). Sets COMMITS,
# GAP (ms) and FIRED.
WRITE_GAP_LIMIT=180
finish() {
  wait_for 60 "the read port of every node" reads_back
  stop_client
  if [[ $WRITER == off && -z $FINAL_WRITE ]]; then
    final_write
  fi
  COMMITS=$(check_commits)
  GAP=''
  if [[ $WRITER == on ]]; then
    GAP=$(longest_write_gap "$T0" "$T_END")
    ((GAP <= WRITE_GAP_LIMIT * 1000)) || fail "no acknowledged write for $((GAP / 1000)) s, more than $WRITE_GAP_LIMIT s"
  fi
  check_alerts
  check_dashboard
}

# The object store, the container s3 at S3_IP, breaks in one of two ways.
# refuse: the store stops and a container with nothing listening takes its
# address, so every connection is refused. hang: the store is paused, so
# connections open and no request is answered.
STORE_GONE=s3-refuse
store_break() {
  case $1 in
    refuse)
      docker stop -t 0 s3 >/dev/null
      docker run -d --name "$STORE_GONE" --network "$NETWORK" --ip "$S3_IP" \
        --entrypoint /bin/sleep "$K3S_IMAGE" 86400 >/dev/null
      ;;
    hang) docker pause s3 >/dev/null ;;
    *) fail "store_break: no mode $1" ;;
  esac
  log "object store: $1"
}

store_restore() {
  case $1 in
    refuse)
      docker rm -f "$STORE_GONE" >/dev/null
      docker start s3 >/dev/null
      ;;
    hang) docker unpause s3 >/dev/null ;;
    *) fail "store_restore: no mode $1" ;;
  esac
  log "object store back"
}

# Writes at least $2 MB of WAL on the primary $1, in transactions of about
# 45 MB into the table live_load of the database postgres, and prints the MB
# written.
write_wal() {
  local pod=$1 mb=$2 start written=0
  psql_on "$pod" -c 'create table if not exists live_load (n int, pad text)'
  start=$(psql_on "$pod" -c 'select pg_current_wal_lsn()')
  while ((written < mb)); do
    psql_on "$pod" -c "insert into live_load select g, repeat(md5(g::text), 30) from generate_series(1, 40000) g"
    psql_on "$pod" -c 'truncate live_load'
    written=$(psql_on "$pod" -c "select floor((pg_current_wal_lsn() - '$start'::pg_lsn) / 1048576)::bigint")
  done
  echo "$written"
}

# The WAL file name of LSN $2 on instance $1, which must be the primary.
wal_file() { psql_on "$1" -c "select pg_walfile_name('$2')"; }

# The WAL file $2 is no longer in the pg_wal of instance $1. Makes a checkpoint
# first, which removes the files older than wal_keep_size.
wal_file_gone() {
  psql_on "$1" -c checkpoint
  local n
  n=$(psql_on "$1" -c "select count(*) from pg_ls_waldir() where name = '$2'")
  [[ $n == 0 ]] || { echo "$2 is still in the pg_wal of $1" >&2; return 1; }
}

# cnpg_compliance_violations of instance $1, read through kubectl
# port-forward, has its 4 checks, each 0.
compliance_zero() {
  local page series
  page=$(metrics_of "$1")
  series=$(awk '/^cnpg_compliance_violations\{/' <<<"$page")
  [[ -n $series && $(wc -l <<<"$series") == 4 ]] || { echo "$1 does not export the 4 compliance checks: ${series:-none}" >&2; return 1; }
  [[ -z $(awk '$2 != 0' <<<"$series") ]] || { echo "$1 has compliance violations: $(awk '$2 != 0' <<<"$series" | paste -sd ' ')" >&2; return 1; }
}

# The backup up.sh starts, so the backup alert sees one, as in a cluster
# with scheduled backups.
FIRST_BACKUP=live-first

# Backup $1 has completed; fails at once when it failed.
backup_completed() {
  local phase
  phase=$(k get backup "$1" -n "$NS" -o jsonpath='{.status.phase}')
  [[ $phase != failed ]] || fail "backup $1 failed: $(k get backup "$1" -n "$NS" -o jsonpath='{.status.error}')"
  [[ $phase == completed ]] || { echo "backup phase: ${phase:-none}" >&2; return 1; }
}

# The monitoring stack: Prometheus with samples/monitoring/rules.yaml and
# Alertmanager with samples/monitoring/alertmanager.yaml, in the namespace the
# chart's NetworkPolicy admits to the metrics port. Prometheus scrapes what
# docs/monitoring.md lists: every instance's exporter every 5 s, the kubelets
# and their cAdvisor, and cert-manager.
PROMETHEUS_IMAGE=prom/prometheus:v3.7.3@sha256:49214755b6153f90a597adcbff0252cc61069f8ab69ce8411285cd4a560e8038
ALERTMANAGER_IMAGE=prom/alertmanager:v0.34.1@sha256:e9733bafb1bdef9b00e25a21f8f99dc26a22224bf16641ad754d1649f4c3357a
PROM_NS=otel

# Starts the stack on node $1, which the scenario must not stop: a rule
# evaluator outside the database's nodes, as in docs/monitoring.md. Waits
# until Prometheus has the metrics of every source and the first backup is
# done, so no alert fires for a state up.sh leaves, and sets MONITOR_START.
start_monitoring() {
  local node=$1 ca
  ca=$(k get secret client-ca -n "$NS" -o jsonpath='{.data.ca\.crt}' | base64 -d)
  k create namespace "$PROM_NS" --dry-run=client -o yaml | k apply -f - >/dev/null
  k create configmap prometheus -n "$PROM_NS" --dry-run=client -o yaml \
    --from-file=rules.yaml="$REPO/samples/monitoring/rules.yaml" \
    --from-literal=ca.crt="$ca" \
    --from-literal=prometheus.yml="$(prometheus_config)" | k apply -f - >/dev/null
  k create configmap alertmanager -n "$PROM_NS" --dry-run=client -o yaml \
    --from-file=alertmanager.yml="$REPO/samples/monitoring/alertmanager.yaml" | k apply -f - >/dev/null
  k apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus
  namespace: $PROM_NS
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: live-prometheus
rules:
  - apiGroups: [""]
    resources: [pods, nodes]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [nodes/metrics]
    verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: live-prometheus
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: live-prometheus
subjects:
  - kind: ServiceAccount
    name: prometheus
    namespace: $PROM_NS
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: $PROM_NS
spec:
  replicas: 1
  selector:
    matchLabels: {app: prometheus}
  template:
    metadata:
      labels: {app: prometheus}
    spec:
      serviceAccountName: prometheus
      nodeSelector: {kubernetes.io/hostname: $node}
      containers:
        - name: prometheus
          image: $PROMETHEUS_IMAGE
          args: [--config.file=/etc/prometheus/prometheus.yml, --storage.tsdb.path=/prometheus]
          ports: [{containerPort: 9090}]
          readinessProbe:
            httpGet: {path: /-/ready, port: 9090}
          volumeMounts:
            - {name: config, mountPath: /etc/prometheus}
            - {name: data, mountPath: /prometheus}
      volumes:
        - {name: config, configMap: {name: prometheus}}
        - {name: data, emptyDir: {}}
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: $PROM_NS
spec:
  selector: {app: prometheus}
  ports: [{port: 9090}]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alertmanager
  namespace: $PROM_NS
spec:
  replicas: 1
  selector:
    matchLabels: {app: alertmanager}
  template:
    metadata:
      labels: {app: alertmanager}
    spec:
      nodeSelector: {kubernetes.io/hostname: $node}
      containers:
        - name: alertmanager
          image: $ALERTMANAGER_IMAGE
          args: [--config.file=/etc/alertmanager/alertmanager.yml, --storage.path=/alertmanager, --cluster.listen-address=]
          ports: [{containerPort: 9093}]
          readinessProbe:
            httpGet: {path: /-/ready, port: 9093}
          volumeMounts:
            - {name: config, mountPath: /etc/alertmanager}
            - {name: data, mountPath: /alertmanager}
      volumes:
        - {name: config, configMap: {name: alertmanager}}
        - {name: data, emptyDir: {}}
---
apiVersion: v1
kind: Service
metadata:
  name: alertmanager
  namespace: $PROM_NS
spec:
  selector: {app: alertmanager}
  ports: [{port: 9093}]
YAML
  local d
  for d in prometheus alertmanager; do
    timeout 330 kubectl rollout status "deployment/$d" -n "$PROM_NS" --timeout=300s >/dev/null ||
      fail "$d not ready after 300s"
  done
  wait_for 300 "Prometheus with the metrics of every source" prom_has_every_source
  wait_for 600 "the first backup completed" backup_completed "$FIRST_BACKUP"
  MONITOR_START=$(now_ms)
  log "monitoring on $node"
}

# Prometheus has, for every instance, its query metrics and data disk, and
# the chart's two certificates.
prom_has_every_source() {
  prom_count 3 "count by (pod) (cnpg_compliance_violations{cluster=\"$CLUSTER\"}) == 4" &&
    prom_count 3 "cnpg_sample:data_disk_used_ratio{cluster=\"$CLUSTER\"}" &&
    prom_count 2 "cnpg_sample:certificate_expiration_timestamp_seconds{cluster=\"$CLUSTER\"}"
}

# The scrape of docs/monitoring.md, with the CA of the server certificate and
# one of its dnsNames in desired.yaml; the kubelets with the ServiceAccount's
# token and the cluster's CA, which signs their serving certificates on k3s;
# cert-manager.
prometheus_config() {
  cat <<'YAML'
global: {scrape_interval: 15s, evaluation_interval: 15s}
rule_files: [/etc/prometheus/rules.yaml]
alerting:
  alertmanagers:
    - static_configs: [{targets: ["alertmanager:9093"]}]
scrape_configs:
  - job_name: cnpg
    scrape_interval: 5s
    scheme: https
    tls_config: {ca_file: /etc/prometheus/ca.crt, server_name: pg-rw}
    kubernetes_sd_configs:
      - role: pod
        namespaces: {names: [databases]}
    relabel_configs:
      - {source_labels: [__meta_kubernetes_pod_label_cnpg_io_podRole], regex: instance, action: keep}
      - {source_labels: [__meta_kubernetes_pod_container_port_number], regex: "9187", action: keep}
      - {source_labels: [__meta_kubernetes_namespace], target_label: namespace}
      - {source_labels: [__meta_kubernetes_pod_name], target_label: pod}
      - {source_labels: [__meta_kubernetes_pod_label_cnpg_io_cluster], target_label: cluster}
      - {source_labels: [__meta_kubernetes_pod_node_name], target_label: node}
  - job_name: kubelet
    scheme: https
    authorization: {credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token}
    tls_config: {ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt}
    kubernetes_sd_configs: [{role: node}]
    relabel_configs:
      - {source_labels: [__meta_kubernetes_node_name], target_label: node}
  - job_name: cadvisor
    scheme: https
    metrics_path: /metrics/cadvisor
    authorization: {credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token}
    tls_config: {ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt}
    kubernetes_sd_configs: [{role: node}]
    relabel_configs:
      - {source_labels: [__meta_kubernetes_node_name], target_label: node}
  - job_name: cert-manager
    honor_labels: true
    kubernetes_sd_configs:
      - role: pod
        namespaces: {names: [cert-manager]}
    relabel_configs:
      - {source_labels: [__meta_kubernetes_pod_container_port_number], regex: "9402", action: keep}
YAML
}

# The result of the PromQL query $1 as Prometheus's JSON, through the API
# server's service proxy.
prom_query() {
  local q out
  q=$(jq -rn --arg q "$1" '$q | @uri')
  out=$(k get --raw "/api/v1/namespaces/$PROM_NS/services/prometheus:9090/proxy/api/v1/query?query=$q") || return 1
  jq -e '.status == "success"' <<<"$out" >/dev/null || { echo "Prometheus answered: $out" >&2; return 1; }
  echo "$out"
}

# Prometheus has $1 series of query $2.
prom_count() {
  local result n
  result=$(prom_query "$2") || return 1
  n=$(jq '.data.result | length' <<<"$result")
  [[ $n == "$1" ]] || { echo "$n series of $2, not $1" >&2; return 1; }
}

# The firing alerts, as "<alertname> <pod>" lines, "-" for an alert without a
# pod.
firing_alerts() {
  local result
  result=$(prom_query 'ALERTS{alertstate="firing"}') || return 1
  jq -r '.data.result[].metric | "\(.alertname) \(.pod // "-")"' <<<"$result" | sort -u
}

# Alert $1 fires for pod $2.
alert_firing() {
  local alerts
  alerts=$(firing_alerts) || return 1
  grep -qxF "$1 $2" <<<"$alerts" || { echo "firing: $(paste -sd ';' <<<"$alerts")" >&2; return 1; }
}

# Alert $1 does not fire for pod $2.
alert_resolved() {
  local alerts
  alerts=$(firing_alerts) || return 1
  ! grep -qxF "$1 $2" <<<"$alerts" || { echo "$1 still fires for $2" >&2; return 1; }
}

no_alert_firing() {
  local alerts
  alerts=$(firing_alerts) || return 1
  [[ -z $alerts ]] || { echo "still firing: $(paste -sd ';' <<<"$alerts")" >&2; return 1; }
}

# The alerts that fired since the monitoring started, as "<alertname> <pod>"
# lines.
fired_alerts() {
  local window result
  window=$((($(now_ms) - MONITOR_START) / 1000 + 1))
  result=$(prom_query "max by (alertname, pod) (max_over_time(ALERTS{alertstate=\"firing\"}[${window}s]))") || return 1
  jq -r '.data.result[].metric | "\(.alertname) \(.pod // "-")"' <<<"$result" | sort -u
}

# Alertmanager's alerts named $1, as "<pod> <state>" lines, state active or
# suppressed. Alertmanager's API, through the API server's service proxy.
am_alerts() {
  local out
  out=$(k get --raw "/api/v1/namespaces/$PROM_NS/services/alertmanager:9093/proxy/api/v2/alerts") || return 1
  jq -r --arg name "$1" '.[] | select(.labels.alertname == $name) | "\(.labels.pod // "-") \(.status.state)"' <<<"$out" | sort
}

# Alertmanager holds alert $1 for pod $2 in state $3.
am_alert_is() {
  local alerts
  alerts=$(am_alerts "$1") || return 1
  grep -qxF "$2 $3" <<<"$alerts" || { echo "Alertmanager has $1: $(paste -sd ';' <<<"$alerts")" >&2; return 1; }
}

# Sends critical alert $1 for pod $2 of the database to Alertmanager, as the
# rule evaluator would, for 2 min, with amtool in its pod.
am_send() {
  k exec -n "$PROM_NS" deploy/alertmanager -- amtool alert add "$1" severity=critical \
    "namespace=$NS" "cluster=$CLUSTER" "pod=$2" \
    --end="$(date -u -d '+2 min' +%FT%TZ)" --alertmanager.url=http://localhost:9093 >/dev/null
}

# The alerts a scenario expects to fire, and those it allows: alerts that are
# true when they fire, but whether they fire depends on how long a step of
# the event takes compared with the alert's waiting time. As
# "<alertname> <pod>" lines.
EXPECTED_ALERTS=()
ALLOWED_ALERTS=()
expect_alert() { EXPECTED_ALERTS+=("$1 $2"); }
allow_alert() { ALLOWED_ALERTS+=("$1 $2"); }

# Every alert has resolved within 3 min, every expected alert fired since the
# monitoring started, and no other one but the allowed ones. Sets FIRED.
check_alerts() {
  local expected missing other
  wait_for 180 "every alert resolved" no_alert_firing
  FIRED=$(fired_alerts) || fail "Prometheus did not answer"
  expected=$(printf '%s\n' "${EXPECTED_ALERTS[@]}" | sed '/^$/d' | sort -u)
  missing=$(comm -23 <(echo "$expected") <(echo "$FIRED") | sed '/^$/d')
  other=$(comm -13 <(printf '%s\n' "$expected" "${ALLOWED_ALERTS[@]}" | sed '/^$/d' | sort -u) <(echo "$FIRED") | sed '/^$/d')
  [[ -z $missing ]] || fail "expected alerts did not fire: $(paste -sd ';' <<<"$missing"); fired: $(paste -sd ';' <<<"${FIRED:-none}")"
  [[ -z $other ]] || fail "alerts fired that the scenario does not expect: $(paste -sd ';' <<<"$other")"
}

# Every query of samples/monitoring/dashboard.json, with the dashboard's
# variables set to the database, returns data: each panel at least one value
# that is not NaN, which the red tiles return when there is none.
dashboard_has_data() {
  local panel title expr result values
  while read -r panel; do
    title=$(jq -r .title <<<"$panel")
    values=0
    while read -r expr; do
      expr=${expr//"\$namespace"/$NS}
      expr=${expr//"\$cluster"/$CLUSTER}
      expr=${expr//"\$__rate_interval"/1m}
      result=$(prom_query "$expr") || { echo "the query of dashboard panel $title failed: $expr" >&2; return 1; }
      values=$((values + $(jq '[.data.result[] | select(.value[1] != "NaN")] | length' <<<"$result")))
    done < <(jq -r '.targets[].expr' <<<"$panel")
    ((values > 0)) || { echo "dashboard panel $title has no data" >&2; return 1; }
  done < <(jq -c '.panels[] | ., .panels[]? | select(.targets)' "$REPO/samples/monitoring/dashboard.json")
}

# Some sources report again only a while after the event: a started node's
# kubelet, cert-manager after its leader moved, a new primary's replication
# figures.
check_dashboard() { wait_for 180 "data in every dashboard panel" dashboard_has_data; }

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
  row "alerts that fired, as expected" "$(paste -sd ';' <<<"${FIRED:-none}" | sed 's/;/, /g')"
}
print_summary() {
  local line
  for line in "${SUMMARY[@]}"; do
    echo "$line"
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then echo "$line" >>"$GITHUB_STEP_SUMMARY"; fi
  done
}
