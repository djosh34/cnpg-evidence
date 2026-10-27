#!/usr/bin/env bash
# Provides JSON-check output and semicolon-separated text helpers.
# Usage: source lib.sh; add_check ID true|false VALUE RAW; joined TEXT...;
#   listed TEXT...
# Exit: helpers return 0 on success, nonzero on command errors.
set -euo pipefail
shopt -s inherit_errexit nullglob

lib_here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$lib_here/../lib/common.sh"

joined() {
  local out
  out=$(printf '%s; ' "$@")
  echo "${out%; }"
}

# The texts joined, or none without any.
listed() {
  if (($#)); then joined "$@"; else echo none; fi
}

# VALUE is the result in the terms of the check's rule, so a passing check on
# any host has the same value. RAW is what the check read.
add_check() {
  jq -n --arg id "$1" --arg ok "$2" --arg value "$3" --arg raw "$4" \
    '{id: $id, ok: ($ok == "true"), value: $value, raw: $raw}'
}
