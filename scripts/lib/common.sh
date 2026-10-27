# shellcheck shell=bash
# Shared helpers for the scripts in scripts/. Logs go to stderr, so stdout
# stays one JSON document.

log() { echo "${0##*/}: $*" >&2; }

# Exit code 2 means the script itself failed, not a check.
die() {
  log "error: $*"
  exit 2
}

have() { command -v "$1" >/dev/null 2>&1; }

# The time a document is collected: UTC, ISO 8601.
collected_at() { date -u +%Y-%m-%dT%H:%M:%SZ; }
