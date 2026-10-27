#!/usr/bin/env bash
# Tests the document keys, the node name and the check order.
# Usage: bash output.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib/test.sh"

checks='{"id":"one","ok":true,"value":"none","raw":"nothing found"}
{"id":"two","ok":false,"value":"permissive","raw":"/sys/fs/selinux/enforce = 0"}'
facts='{"hostname":"node-a","selinux":"permissive"}'

actual=$(jq -s --slurpfile facts <(echo "$facts") --arg collected_at 2026-01-02T03:04:05Z \
  --arg node '' -f "$here/output.jq" <<<"$checks")
expected=$(cat <<'JSON'
{"kind":"actual","source":"host-check","collected_at":"2026-01-02T03:04:05Z","node":"node-a",
 "collected":{"hostname":"node-a","selinux":"permissive"},
 "checks":[{"id":"one","ok":true,"value":"none","raw":"nothing found"},
           {"id":"two","ok":false,"value":"permissive","raw":"/sys/fs/selinux/enforce = 0"}]}
JSON
)
same "document keys, hostname as node, checks in order" "$expected" "$actual"
same_text "keys in order" "kind source collected_at node collected checks" "$(jq -r 'keys_unsorted | join(" ")' <<<"$actual")"

actual=$(jq -s --slurpfile facts <(echo "$facts") --arg collected_at 2026-01-02T03:04:05Z \
  --arg node worker-1 -f "$here/output.jq" <<<"$checks")
same_text "--node overrides the hostname" worker-1 "$(jq -r .node <<<"$actual")"

finish
