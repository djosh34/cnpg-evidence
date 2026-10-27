# shellcheck shell=bash
# Provides JSON records, command-result matching, uid changes and namespaced queries.
# Usage: source probe.sh; deny|allow NAME TARGET EXPECTED PATTERN COMMAND [ARG...]
#   add_probe NAME TARGET EXPECTED WANTED VALUE ACTUAL; as_uid UID GID COMMAND [ARG...]
#   kjson NAMESPACE RESOURCE [ARG...]
# A record's value is denied (the expected denial), allowed (the attempt got
# through) or error (anything else). It is ok when the value is WANTED.
# Exit: helpers return 0 for a record; command errors propagate from as_uid/kjson.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

add_probe() {
  jq -nc --arg probe "$1" --arg target "$2" --arg expected "$3" --arg wanted "$4" \
    --arg value "$5" --arg actual "$6" \
    '{probe: $probe, target: $target, expected: $expected, value: $value,
      ok: ($value == $wanted), actual: $actual}'
}

deny() {
  local probe=$1 target=$2 expected=$3 pattern=$4 output value=error
  shift 4

  if output=$("$@" 2>&1); then
    output="succeeded: $output" value=allowed
  elif [[ $output =~ $pattern ]]; then
    value=denied
  fi

  output=${output//$'\n'/ }
  add_probe "$probe" "$target" "$expected" denied "$value" "${output:0:400}"
}

allow() {
  local probe=$1 target=$2 expected=$3 pattern=$4 output value=error
  shift 4

  if output=$("$@" 2>&1) && [[ $output =~ $pattern ]]; then
    value=allowed
  fi

  output=${output//$'\n'/ }
  add_probe "$probe" "$target" "$expected" allowed "$value" "${output:0:400}"
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
