#!/usr/bin/env bash
# Checks exit status and stdout after usage, desired-value and collection failures.
# Usage: bash prove.test.sh
# Exit: 0 all assertions pass, 1 an assertion fails, nonzero on a test error.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../lib/test.sh"

values='{"cluster": {"name": "pg", "namespace": "databases", "instances": 3}, "caSecret": "client-ca",
         "rwLoadBalancer": {"name": "pg-rw-lb"}, "network": {"operatorNamespace": "cnpg-system"},
         "replication": {"commonName": "pg-replication"}, "databases": []}'

# The node tools may be missing where the tests run.
psql() { return 2; }
setpriv() { return 2; }
pgrep() { return 2; }
export -f psql setpriv pgrep

# exits NAME STDIN ARGS...: exit 2 and nothing on stdout. Keeps stderr in errors.
exits() {
  local name=$1 input=$2 status=0 actual
  shift 2
  actual=$(bash "$here/prove.sh" "$@" <<<"$input" 2>"$errors_file") || status=$?
  same_text "$name exit" 2 "$status"
  same_text "$name stdout" '' "$actual"
  errors=$(<"$errors_file")
}
errors_file=$(mktemp)
trap 'rm -f "$errors_file"' EXIT

for arguments in --unknown '--postgres-uid nope' --node-root '--namespace databases' '--cluster pg' \
  '--lb-service pg-rw-lb'; do
  # shellcheck disable=SC2086
  exits "$arguments" "$values" $arguments
done

exits 'values that are not JSON' 'cluster: pg'
same_text 'values that are not JSON say so' 1 "$(grep -c 'not JSON' <<<"$errors")"
exits 'no values' ''
same_text 'no values say stdin is empty' 1 "$(grep -c 'stdin is empty' <<<"$errors")"
exits 'values without the rw LoadBalancer' "$(jq -c 'del(.rwLoadBalancer)' <<<"$values")"
same_text 'values without the rw LoadBalancer say what is needed' 1 "$(grep -c 'the desired state needs' <<<"$errors")"

kubectl() { echo 'API denied' >&2; return 2; }
export -f kubectl
exits 'child collection error' "$values"
finish
