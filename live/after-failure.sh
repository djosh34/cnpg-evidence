#!/usr/bin/env bash
# Prints the cluster's state after a failed scenario: starts every stopped
# node first, then shows the nodes, the pods, the Cluster, the operator's
# errors and the end of the client's logs. A step that fails is reported and
# the next one runs.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

show() {
  echo "== $*"
  "$@" || echo "after-failure.sh: failed with exit code $?: $*" >&2
}

operator_errors() {
  k logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg --prefix --tail=-1 |
    grep -iE "error|failover|switchover|leader" | tail -100
}

# How often docker restarted each node's container, and k3s's last fatal
# lines, from before the start below.
node_restarts() {
  local n
  for n in "${NODES[@]}"; do
    docker inspect -f "$n: restarted {{.RestartCount}} times, running since {{.State.StartedAt}}" "$n"
    docker logs "$n" 2>&1 | awk '/level=fatal|panic:/' | tail -5
  done
}

show node_restarts
show docker ps -a --format '{{.Names}} {{.Status}}'
for n in "${NODES[@]}"; do
  show docker start "$n"
done
use_api_of "${NODES[1]}"
show poll 120 k get nodes
show k get nodes -o wide
show k get pods -A -o wide
show k get cluster "$CLUSTER" -n "$NS" -o jsonpath='{.status.phase}{"\n"}{.status.phaseReason}{"\n"}'
# JSON, since the text output runs du in an instance.
show timeout 60 kubectl cnpg status "$CLUSTER" -n "$NS" -o json
show operator_errors
# The monitoring stack's view: the alerts that fire and the scrapes that fail.
show firing_alerts
show prom_query 'up == 0'
for f in write.log write.err read.log read.err; do
  show tail -20 "$LIVE_WORK/$f"
done
