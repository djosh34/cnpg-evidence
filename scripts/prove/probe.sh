# shellcheck shell=bash
# Provides JSON records, command-result matching, uid changes and namespaced queries.
# Usage: source probe.sh; deny|allow NAME EXPECTED PATTERN COMMAND [ARG...]
#   add_probe NAME EXPECTED ACTUAL OK; as_uid UID GID COMMAND [ARG...]
#   kjson NAMESPACE RESOURCE [ARG...]
# Exit: helpers return 0 for a record; command errors propagate from as_uid/kjson.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

add_probe() {
  jq -nc --arg probe "$1" --arg expected "$2" --arg actual "$3" --arg ok "$4" \
    '{probe: $probe, expected: $expected, actual: $actual, ok: ($ok == "true")}'
}

deny() {
  local probe=$1 expected=$2 pattern=$3 output ok=false
  shift 3

  if output=$("$@" 2>&1); then
    output="succeeded: $output"
  elif [[ $output =~ $pattern ]]; then
    ok=true
  fi

  output=${output//$'\n'/ }
  add_probe "$probe" "$expected" "${output:0:400}" "$ok"
}

allow() {
  local probe=$1 expected=$2 pattern=$3 output ok=false
  shift 3

  if output=$("$@" 2>&1) && [[ $output =~ $pattern ]]; then
    ok=true
  fi

  output=${output//$'\n'/ }
  add_probe "$probe" "$expected" "${output:0:400}" "$ok"
}

as_uid() {
  local uid=$1 gid=$2
  shift 2

  setpriv --reuid="$uid" --regid="$gid" --clear-groups \
    --bounding-set=-all --inh-caps=-all --ambient-caps=-all --no-new-privs \
    env HOME=/ "$@"
}

kjson() {
  local namespace=$1
  shift
  kubectl -n "$namespace" get -o json "$@"
}
