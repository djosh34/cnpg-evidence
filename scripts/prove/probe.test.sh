#!/usr/bin/env bash
# Checks command-result matching, successful controls, uid-change flags and query arguments.
# Usage: bash probe.test.sh
# Exit: 0 all assertions pass, 1 an assertion fails, nonzero on a test error.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../lib/test.sh"

refused() { echo 'Connection refused' >&2; return 2; }
connected() { echo connected; }
broken() { echo 'command missing' >&2; return 127; }
export -f refused connected broken

result=$(bash -c 'source "$1"; deny test denied refused refused' probe "$here/probe.sh")
same 'matching denial' '{"probe":"test","expected":"denied","actual":"Connection refused","ok":true}' "$result"
result=$(bash -c 'source "$1"; deny test denied refused connected' probe "$here/probe.sh")
same_text 'successful denial fails' false "$(jq -r .ok <<<"$result")"
result=$(bash -c 'source "$1"; deny test denied refused broken' probe "$here/probe.sh")
same_text 'unrelated failure fails' false "$(jq -r .ok <<<"$result")"
result=$(bash -c 'source "$1"; allow test allowed "^connected$" connected' probe "$here/probe.sh")
same_text 'working control' true "$(jq -r .ok <<<"$result")"
result=$(bash -c 'source "$1"; allow test allowed "^connected$" refused' probe "$here/probe.sh")
same_text 'broken control fails' false "$(jq -r .ok <<<"$result")"

setpriv() { printf '%s\n' "$@"; }
export -f setpriv
result=$(bash -c 'source "$1"; as_uid 26 26 true' probe "$here/probe.sh")
expected=$(printf '%s\n' --reuid=26 --regid=26 --clear-groups --bounding-set=-all \
  --inh-caps=-all --ambient-caps=-all --no-new-privs env HOME=/ true)
same_text 'uid has no groups or capabilities' "$expected" "$result"
kubectl() { printf '%s\n' "$@"; }
export -f kubectl
result=$(bash -c 'source "$1"; kjson custom-ns cluster custom-pg' probe "$here/probe.sh")
same_text 'namespace comes from the query argument' \
  "$(printf '%s\n' -n custom-ns get -o json cluster custom-pg)" "$result"
finish
