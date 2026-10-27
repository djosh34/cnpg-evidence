#!/usr/bin/env bash
# Checks the document keys, the grouping of attempts by probe and the row order.
# Usage: bash output.test.sh
# Exit: 0 all assertions pass, 1 an assertion fails, nonzero on a test error.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../lib/test.sh"

output() {
  jq -s --arg collected_at 2026-01-02T03:04:05Z --arg node node-a --arg namespace databases \
    --arg cluster pg -f "$here/output.jq"
}

actual=$(output <<'JSON'
{"probe":"one","target":"192.0.2.1:5432","expected":"refused","value":"denied","ok":true,"actual":"rejected"}
{"probe":"two","target":"10.43.0.1:443","expected":"connected","value":"allowed","ok":true,"actual":"connected"}
{"probe":"one","target":"192.0.2.2:5432","expected":"refused","value":"denied","ok":true,"actual":"rejected again"}
JSON
)
expected=$(cat <<'JSON'
{"kind":"actual","source":"prove","collected_at":"2026-01-02T03:04:05Z","node":"node-a",
 "namespace":"databases","cluster":"pg","probes":[
{"probe":"one","expected":"refused","value":"denied","ok":true,"raw":[
  {"target":"192.0.2.1:5432","value":"denied","actual":"rejected"},
  {"target":"192.0.2.2:5432","value":"denied","actual":"rejected again"}]},
{"probe":"two","expected":"connected","value":"allowed","ok":true,"raw":[
  {"target":"10.43.0.1:443","value":"allowed","actual":"connected"}]}]}
JSON
)
same 'attempts grouped by probe, in first-seen order' "$expected" "$actual"
same_text 'keys in order' "kind source collected_at node namespace cluster probes" \
  "$(jq -r 'keys_unsorted | join(" ")' <<<"$actual")"

actual=$(output <<'JSON'
{"probe":"one","target":"192.0.2.1:5432","expected":"refused","value":"denied","ok":true,"actual":"rejected"}
{"probe":"one","target":"192.0.2.2:5432","expected":"refused","value":"allowed","ok":false,"actual":"succeeded: postgres"}
{"probe":"one","target":"192.0.2.3:5432","expected":"refused","value":"denied","ok":true,"actual":"rejected"}
JSON
)
same 'one attempt that gets through fails the row and shows in its value' \
  '{"value":"denied, allowed","ok":false}' "$(jq -c '.probes[0] | {value, ok}' <<<"$actual")"

same 'no records, no rows' '[]' "$(output </dev/null | jq -c .probes)"
finish
