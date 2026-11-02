#!/usr/bin/env bash
# A switchover with kubectl cnpg promote to a replica. The replica must
# become primary within 5 min and, with the writer, take a write within
# 180 s. Every instance must be ready and streaming within 10 min.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

wait_for 600 "three ready instances, two streaming replicas" settled
old=$(primary)
target=$(instances | awk -v p="$old" '$1 != p {print $1; exit}')
start_client

T0=$(now_ms)
k cnpg promote "$CLUSTER" "$target" -n "$NS" >/dev/null
log "promoting $target, primary was $old"
wait_for 300 "$target as primary" primary_is "$target"
promoted=$(now_ms)
if [[ $WRITER == on ]]; then
  wait_first_write "$target" 180
fi
wait_back
finish

summary "### switchover, writer $WRITER"
summary ""
row "Seconds after kubectl cnpg promote $target, primary was $old" ""
summary "|---|---|"
row "$target primary" "$(secs "$promoted")"
if [[ $WRITER == on ]]; then
  row "first write on $target" "$(secs "$FIRST_WRITE")"
fi
common_rows
print_summary
