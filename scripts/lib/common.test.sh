#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/test.sh"

# run CODE: sources common.sh in a child script named probe.sh and runs CODE.
run() {
  bash -c "source '$here/common.sh'; $1" probe.sh
}

same_text "log prints nothing on stdout" "" "$(run 'log reading' 2>/dev/null)"
same_text "log writes to stderr, with the script name" "probe.sh: reading" "$(run 'log reading' 2>&1 >/dev/null)"

code=0
out=$(run 'die "no kubectl"; echo after' 2>/dev/null) || code=$?
same_text "die exits 2" 2 "$code"
same_text "die prints nothing on stdout" "" "$out"
same_text "die logs an error on stderr" "probe.sh: error: no kubectl" "$(run 'die "no kubectl"' 2>&1 >/dev/null || true)"

same_text "have finds bash" yes "$(run 'have bash && echo yes || echo no')"
same_text "have misses a missing tool, silently" no "$(run 'have no-such-tool-here && echo yes || echo no' 2>&1)"

same_text "collected_at is UTC ISO 8601" yes \
  "$(run 'collected_at' | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' && echo yes || echo no)"
same_text "collected_at asks date for UTC" "-u +%Y-%m-%dT%H:%M:%SZ" "$(run 'date() { echo "$*"; }; collected_at')"

finish
