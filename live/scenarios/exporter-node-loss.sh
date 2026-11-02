#!/usr/bin/env bash
# A replica's node is lost for 400 s, then the primary's node for 400 s: each
# longer than the 5 min after which Kubernetes marks the lost pod for
# deletion. The exporters of the instances that are left must keep their
# query metrics all along: Prometheus must get cnpg_compliance_violations
# from the chart's queries and cnpg_pg_replication_in_recovery from CNPG's
# own from each of them at least once in every 15 s. CNPGReplicaDown must
# fire for each lost instance and nothing else.
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

# Instances $2... kept their query metrics from $1 (ms) to now: Prometheus
# got them at least once in every 15 s, three scrapes. A change of the
# Cluster gives each exporter new, empty query results, so a scrape right
# after one can lack them. Adds a row with how many scrapes lacked them.
kept_metrics() {
  local from=$1 window pod series n empty=()
  shift
  window=$((($(now_ms) - from) / 1000))
  for pod in "$@"; do
    for series in "cnpg_compliance_violations{check=\"cn_mapping\", pod=\"$pod\"}" "cnpg_pg_replication_in_recovery{namespace=\"$NS\", pod=\"$pod\"}"; do
      # A 15 s window without a sample counts 0, not nothing: sum makes the
      # count one unlabelled series, which vector(0) then fills.
      n=$(prom_value "min_over_time((sum(count_over_time(${series}[15s])) or vector(0))[${window}s:5s])")
      [[ $n =~ ^[1-9] ]] || fail "$pod went 15 s or longer without $series, $(gaps "$series" "$window")"
      n=$(prom_value "count_over_time(cnpg_collector_up{pod=\"$pod\"}[${window}s]) - on (pod) count_over_time(${series}[${window}s])")
      empty+=("$pod ${series%%\{*} $n")
    done
  done
  row "query metrics never 15 s away from $*, from $(secs "$from") to $(secs "$(now_ms)"); scrapes without them" "$(printf '%s, ' "${empty[@]}" | sed 's/, $//')"
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
