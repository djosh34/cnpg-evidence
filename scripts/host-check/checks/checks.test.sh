#!/usr/bin/env bash
# Tests check dispatch and collection error propagation.
# Usage: bash checks.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

# The checks of the desired host-check document, in its order.
desired=$(
  jq -n '{cluster: {name: "pg", namespace: "databases", instances: 3}, caSecret: "client-ca",
          rwLoadBalancer: {name: "pg-rw-lb"}, network: {operatorNamespace: "cnpg-system", otelNamespace: "otel"},
          replication: {commonName: "pg-replication"}, databases: []}' |
    bash "$here/../../desired/desired.sh" --source host-check |
    jq -r '[.checks[].id] | join(" ")'
)

# Each stub check is named after its script.
bash() {
  local id=${1##*/}
  echo "{\"id\":\"${id%.sh}\",\"ok\":true,\"value\":\"none\",\"raw\":\"fixture\"}"
}
export -f bash
actual=$(/bin/bash "$here/checks.sh" 26 26 /storage <<<'{}' | jq -s -r 'map(.id) | join(" ")')
same_text "all checks invoked" 13 "$(wc -w <<<"$actual")"
same_text "the checks of the desired document, in order" "$desired" "$actual"
bash() { return 7; }
export -f bash
status=0
output=$(/bin/bash "$here/checks.sh" 26 26 /storage <<<'{}') || status=$?
same_text "child failures stop collection" 7 "$status"
same_text "failed collection stdout" '' "$output"

unset -f bash
getent() { return 1; }
export -f getent
status=0
output=$(/bin/bash "$here/checks.sh" 26 26 /storage <<<'{}') || status=$?
same_text "account enumeration failure stops checks" 2 "$status"
same "only the preceding SELinux check was printed" '["selinux-enforcing"]' \
  "$(jq -s 'map(.id)' <<<"$output")"

finish
