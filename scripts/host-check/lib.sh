#!/usr/bin/env bash
# Provides JSON-check output and semicolon-separated detail helpers.
# Usage: source lib.sh; add_check ID true|false DETAIL; joined TEXT...
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

add_check() {
  jq -n --arg id "$1" --arg ok "$2" --arg detail "$3" \
    '{id: $id, ok: ($ok == "true"), detail: $detail}'
}
