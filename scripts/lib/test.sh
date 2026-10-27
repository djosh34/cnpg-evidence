# shellcheck shell=bash
# Helpers for the *.test.sh files. A test file sources this, runs its cases
# with same or same_text, and ends with finish.

failures=0

pass() { echo "ok   $1"; }

fail() {
  echo "FAIL $1"
  failures=$((failures + 1))
}

# same NAME EXPECTED ACTUAL: two JSON documents, equal after sorting keys.
same() {
  if diff <(jq -S . <<<"$2") <(jq -S . <<<"$3") >&2; then
    pass "$1"
  else
    fail "$1"
  fi
}

# same_text NAME EXPECTED ACTUAL: two texts, equal line by line.
same_text() {
  if diff <(echo "$2") <(echo "$3") >&2; then
    pass "$1"
  else
    fail "$1"
  fi
}

finish() {
  if ((failures > 0)); then
    exit 1
  fi
}
