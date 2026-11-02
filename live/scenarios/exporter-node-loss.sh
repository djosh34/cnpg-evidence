#!/usr/bin/env bash
# A replica's node is lost for 400 s, then the primary's node for 400 s: each
# longer than the 5 min after which Kubernetes marks the lost pod for
# deletion. The exporters of the instances that are left must keep their
# query metrics all along: in every scrape of each of them, Prometheus gets
# cnpg_compliance_violations from the chart's queries and
# cnpg_pg_replication_in_recovery from CNPG's own. CNPGReplicaDown must fire
# for each lost instance and nothing else.
#
# While CNPGReplicaDown fires for the lost replica, the scenario sends
# Alertmanager CNPGMetricsMissing for that replica and for another instance:
# the sample's configuration must mute the first and not the second.
#
# Every instance must be ready and streaming within 10 min of each start.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

DOWN_SECONDS=400

# The scrapes of instance $1 from $2 (ms) to now that lack the series $3,
# a selector without its closing brace, to which the pod is added.
scrapes_without() {
  local window result
  window=$((($(now_ms) - $2) / 1000))
  result=$(prom_query "count_over_time(cnpg_collector_up{pod=\"$1\"}[${window}s]) - on (pod) count_over_time($3, pod=\"$1\"}[${window}s])") ||
    fail "Prometheus did not answer"
  jq -r '.data.result[0].value[1] // "no data"' <<<"$result"
}

# Instances $2... kept their query metrics in every scrape from $1 (ms) to
# now. Adds a row.
kept_metrics() {
  local from=$1 pod series n
  shift
  for pod in "$@"; do
    for series in 'cnpg_compliance_violations{check="cn_mapping"' 'cnpg_pg_replication_in_recovery{namespace="'"$NS"'"'; do
      n=$(scrapes_without "$pod" "$from" "$series")
      [[ $n == 0 ]] || fail "$n scrapes of $pod from $(secs "$from") s on had no $series}"
    done
  done
  row "every scrape of $* has the query metrics, from $(secs "$from") to $(secs "$(now_ms)")" "yes"
}

wait_for 600 "three ready instances, two streaming replicas" settled
p=$(primary)
replica=$(instances | awk -v p="$p" '$1 != p {print $1; exit}')
other=$(instances | awk -v p="$p" -v r="$replica" '$1 != p && $1 != r {print $1; exit}')
node=$(node_of "$replica")
keep=$(node_of "$other")
use_api_of "$keep"
start_monitoring "$keep"
expect_alert CNPGReplicaDown "$replica"
expect_alert CNPGReplicaDown "$p"
start_client

summary "### exporter-node-loss, writer $WRITER"
summary ""
row "Seconds after the stop of $node, the node of replica $replica" ""
summary "|---|---|"
T0=$(now_ms)
docker stop -t 0 "$node" >/dev/null
log "stopped $node"
wait_for 420 "CNPGReplicaDown firing for $replica" alert_firing CNPGReplicaDown "$replica"
row "CNPGReplicaDown fires for $replica" "$(secs "$(now_ms)")"
wait_for 60 "Alertmanager sending CNPGReplicaDown for $replica" am_alert_is CNPGReplicaDown "$replica" active
am_send CNPGMetricsMissing "$replica"
am_send CNPGMetricsMissing "$other"
wait_for 60 "Alertmanager muting CNPGMetricsMissing for $replica" am_alert_is CNPGMetricsMissing "$replica" suppressed
wait_for 60 "Alertmanager sending CNPGMetricsMissing for $other" am_alert_is CNPGMetricsMissing "$other" active
row "Alertmanager mutes CNPGMetricsMissing for $replica, not for $other" "$(secs "$(now_ms)")"
sleep_until "$DOWN_SECONDS"
primary_is "$p" || fail "the primary moved away from $p while $node was down"
kept_metrics "$T0" "$p" "$other"
docker start "$node" >/dev/null
STARTED=$(now_ms)
row "$node started" "$(secs "$STARTED")"
wait_back
row "every instance ready and streaming" "$(secs "$BACK")"

summary ""
old=$p
node=$(node_of "$old")
row "Seconds after the stop of $node, the node of primary $old" ""
summary "|---|---|"
T0=$(now_ms)
docker stop -t 0 "$node" >/dev/null
log "stopped $node"
wait_for 600 "a primary other than $old" primary_not "$old"
row "$(primary) primary" "$(secs "$(now_ms)")"
wait_for 420 "CNPGReplicaDown firing for $old" alert_firing CNPGReplicaDown "$old"
row "CNPGReplicaDown fires for $old" "$(secs "$(now_ms)")"
sleep_until "$DOWN_SECONDS"
kept_metrics "$T0" "$replica" "$other"
docker start "$node" >/dev/null
STARTED=$(now_ms)
row "$node started" "$(secs "$STARTED")"
wait_back
finish
common_rows
print_summary
