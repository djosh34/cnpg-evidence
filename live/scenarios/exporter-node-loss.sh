#!/usr/bin/env bash
# A replica's node is lost for 400 s, then the primary's node for 400 s: each
# longer than the 5 min after which Kubernetes marks the lost pod for
# deletion. The exporters of the instances that are left must keep their
# query metrics all along: in every 15 s in which one answers, at least one
# answer has cnpg_compliance_violations from the chart's queries and
# cnpg_pg_replication_in_recovery from CNPG's own, and none goes 60 s
# without answering. CNPGReplicaDown must fire for each lost instance and
# nothing else. The summary gives each instance's answers without them and
# its failed scrapes.
#
# Each phase starts only once every exporter's last answer has those two
# series. The check's first 15 s reach back before the node stop, and an
# instance whose node just came back can answer without them for a few
# seconds after its pod is ready.
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
# Right after a node stops, scrapes of the other instances took up to 39 s
# to answer again in tests; the cause is not known.
NO_ANSWER_LIMIT=60

# Answers Prometheus's query $1 with its one value, or "no data".
prom_value() {
  local result
  result=$(prom_query "$1") || fail "Prometheus did not answer: $1"
  jq -r '.data.result[0].value[1] // "no data"' <<<"$result"
}

# The times without a sample of series $1 for 15 s or longer in the last $2
# seconds, in seconds after T0.
gaps() {
  local result
  result=$(prom_query "$1[$2s]") || fail "Prometheus did not answer"
  jq -r --argjson t0 "$T0" --argjson now "$(now_ms)" --argjson w "$2" '
    [($now / 1000 - $w), (.data.result[0].values // [] | map(.[0]))[], $now / 1000] as $t
    | [range(1; $t | length) | select($t[.] - $t[. - 1] >= 15) | "from \($t[. - 1] - $t0 / 1000 | floor) s to \($t[.] - $t0 / 1000 | floor) s"]
    | if length == 0 then "no gap found" else join(", ") end' <<<"$result"
}

# Sets SERIES to the two query metrics the checks read for instance $1: the
# chart's cn_mapping check and CNPG's in_recovery.
series_of() {
  SERIES=("cnpg_compliance_violations{check=\"cn_mapping\", pod=\"$1\"}" "cnpg_pg_replication_in_recovery{namespace=\"$NS\", pod=\"$1\"}")
}

# Instances $2... kept their query metrics from $1 (ms) to now: in every
# 15 s in which an instance's exporter answered, at least one answer had
# them. A change of the Cluster gives each exporter new, empty query
# results, so one answer right after one can lack them. And no exporter went
# NO_ANSWER_LIMIT seconds without answering: right after a node is lost,
# scrapes can time out for a while. Adds a row per instance with the answers
# without query metrics, the failed scrapes and when it did not answer.
kept_metrics() {
  local from=$1 window pod series n empty scrapes
  shift
  window=$((($(now_ms) - from) / 1000))
  for pod in "$@"; do
    empty=()
    scrapes=$(scrapes_of "$pod" "$window")
    prom_count 0 "min_over_time((sum(count_over_time(cnpg_collector_up{pod=\"$pod\"}[${NO_ANSWER_LIMIT}s])) or vector(0))[${window}s:5s]) == 0" ||
      fail "the exporter of $pod did not answer for ${NO_ANSWER_LIMIT} s or longer: $scrapes"
    series_of "$pod"
    for series in "${SERIES[@]}"; do
      if ! prom_count 0 "max_over_time((sum(count_over_time(cnpg_collector_up{pod=\"$pod\"}[15s])) > 0 unless on () sum(count_over_time(${series}[15s])))[${window}s:5s])"; then
        n=$(gaps "$series" "$window")
        fail "the exporter of $pod answered for 15 s or longer without $series, $n"
      fi
      n=$(prom_value "count_over_time(cnpg_collector_up{pod=\"$pod\"}[${window}s]) - on (pod) count_over_time(${series}[${window}s])")
      empty+=("$n without ${series%%\{*}")
    done
    row "$pod from $(secs "$from") to $(secs "$(now_ms)"): answers" "$(printf '%s, ' "${empty[@]}")$scrapes"
  done
}

# Every instance's exporter answered its last scrape with the two series
# kept_metrics checks: Prometheus has both for each instance now. An answer
# without one, or a failed scrape, leaves Prometheus without it until the
# next answer that has it.
exporters_answer() {
  local pods pod series
  pods=$(instance_pods) || return 1
  for pod in $pods; do
    series_of "$pod"
    for series in "${SERIES[@]}"; do
      prom_count 1 "$series" || return 1
    done
  done
}

# How the scrapes of instance $1 in the last $2 seconds went: how many
# failed, the longest, and the times without cnpg_collector_up for 15 s or
# longer.
scrapes_of() {
  local failed all longest none
  failed=$(prom_value "count_over_time(up{pod=\"$1\"}[$2s]) - sum_over_time(up{pod=\"$1\"}[$2s])")
  all=$(prom_value "count_over_time(up{pod=\"$1\"}[$2s])")
  longest=$(prom_value "max_over_time(scrape_duration_seconds{pod=\"$1\"}[$2s])")
  none=$(gaps "cnpg_collector_up{pod=\"$1\"}" "$2")
  echo "$failed of $all scrapes failed, the longest took $longest s, no answer: $none"
}

wait_for 600 "three ready instances, two streaming replicas" settled
p=$(primary)
replica=$(instances | awk -v p="$p" '$1 != p && !found++ {print $1}')
other=$(instances | awk -v p="$p" -v r="$replica" '$1 != p && $1 != r && !found++ {print $1}')
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
wait_for 60 "every exporter answering with its query metrics" exporters_answer
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
wait_for 60 "every exporter answering with its query metrics" exporters_answer
row "every exporter answers with its query metrics" "$(secs "$(now_ms)")"

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
wait_for 60 "every exporter answering with its query metrics" exporters_answer
finish
common_rows
print_summary
