#!/usr/bin/env bash
# A replica stops streaming while its exporter keeps answering. In the
# replica pod's network namespace, a firewall rule rejects its connections to
# 5432, and the primary ends the replica's WAL sender. Prometheus scrapes
# every instance with the rules of samples/monitoring/rules.yaml.
# CNPGReplicaDown must fire for the replica within 8 min of the event, the
# rule's 5 min plus scrapes and evaluations, while Prometheus still gets the
# replica's metrics. Then the rule goes; the replica must stream again by
# itself within 10 min, and the alert must resolve within 2 min of that.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

REJECT=(OUTPUT -p tcp --dport 5432 -j REJECT --reject-with tcp-reset)

# Runs iptables "$@" in the network namespace of pod $1 on node $2.
pod_iptables() {
  local pod=$1 node=$2 id pid
  shift 2
  id=$(docker exec "$node" crictl pods -q --namespace "$NS" --name "^$pod\$" --state ready)
  [[ $id =~ ^[0-9a-f]+$ ]] || fail "no single ready pod sandbox for $pod on $node: $id"
  pid=$(docker exec "$node" crictl inspectp -o go-template --template '{{.info.pid}}' "$id")
  docker exec "$node" nsenter --net="/proc/$pid/ns/net" iptables "$@"
}

not_in_replication() {
  local n
  n=$(psql_on "$(primary)" -c "select count(*) from pg_stat_replication where application_name = '$1'")
  [[ $n == 0 ]] || { echo "$1 is in the primary's pg_stat_replication" >&2; return 1; }
}

# Prometheus has $1 series of query $2.
prom_count() {
  local result n
  result=$(prom_query "$2") || return 1
  n=$(jq '.data.result | length' <<<"$result")
  [[ $n == "$1" ]] || { echo "$n series of $2, not $1" >&2; return 1; }
}

alert_resolved() {
  local alerts
  alerts=$(firing_alerts) || return 1
  ! grep -qxF "$1 $2" <<<"$alerts" || { echo "$1 still fires for $2" >&2; return 1; }
}

wait_for 600 "three ready instances, two streaming replicas" settled
start_prometheus
wait_for 300 "Prometheus seeing two streaming replicas" prom_count 2 'cnpg_sample:replica_streaming'
p=$(primary)
replica=$(instances | awk -v p="$p" '$1 != p {print $1; exit}')
node=$(node_of "$replica")
start_client

T0=$(now_ms)
pod_iptables "$replica" "$node" -I "${REJECT[@]}"
psql_on "$p" -c "select pg_terminate_backend(pid) from pg_stat_replication where application_name = '$replica'" >/dev/null
log "cut off $replica from 5432"
wait_for 60 "$replica gone from the primary's pg_stat_replication" not_in_replication "$replica"
STOPPED=$(now_ms)
wait_for 480 "CNPGReplicaDown firing for $replica" alert_firing CNPGReplicaDown "$replica"
FIRED=$(now_ms)
prom_count 1 "cnpg_collector_up{pod=\"$replica\"} == 1" || fail "Prometheus gets no metrics from $replica"
FIRING=$(firing_alerts | paste -sd ',' | sed 's/,/, /g')

pod_iptables "$replica" "$node" -D "${REJECT[@]}"
UNBLOCKED=$(now_ms)
log "removed the rule"
wait_back
wait_for 120 "CNPGReplicaDown resolved for $replica" alert_resolved CNPGReplicaDown "$replica"
RESOLVED=$(now_ms)
finish

summary "### replica-not-streaming, writer $WRITER"
summary ""
row "Seconds after $replica was cut off from 5432" ""
summary "|---|---|"
row "$replica not in the primary's pg_stat_replication" "$(secs "$STOPPED")"
row "CNPGReplicaDown fires for $replica, its metrics still scraped; firing then: $FIRING" "$(secs "$FIRED")"
row "rule removed" "$(secs "$UNBLOCKED")"
row "CNPGReplicaDown resolved" "$(secs "$RESOLVED")"
common_rows
print_summary
