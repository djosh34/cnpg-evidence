#!/usr/bin/env bash
# A switchover on a cluster with no writes: kubectl cnpg promote to a replica,
# and the former primary rejoins as a replica. A former primary that rewinds
# onto an idle primary can wait for the primary's next WAL record
# (docs/samples.md). The target must become primary within 5 min, and every
# instance must be ready and streaming within 10 min. If not, the scenario
# makes its one write then, and every instance must be back within 10 s of
# it. This scenario always runs without the writer, whatever WRITER says;
# the read probes run as in every scenario.
set -euo pipefail
shopt -s inherit_errexit

WRITER=off
# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

wait_for 600 "three ready instances, two streaming replicas" settled
old=$(primary)
target=$(instances | awk -v p="$old" '$1 != p && !found++ {print $1}')
start_monitoring "${NODES[0]}"
start_client

T0=$(now_ms)
k cnpg promote "$CLUSTER" "$target" -n "$NS" >/dev/null
log "promoting $target, primary was $old"
wait_for 300 "$target as primary" primary_is "$target"
promoted=$(now_ms)
wait_back
finish

summary "### quiet-rewind, no writes"
summary ""
row "Seconds after kubectl cnpg promote $target, primary was $old" ""
summary "|---|---|"
row "$target primary" "$(secs "$promoted")"
common_rows
print_summary
