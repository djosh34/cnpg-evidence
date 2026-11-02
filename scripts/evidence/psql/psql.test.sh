#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

# Prints its arguments and the SQL it got, as JSON.
kubectl() {
  jq -nc --arg args "$*" --arg sql "$(cat)" '{args: $args, sql: $sql}'
}
export -f kubectl

actual=$(echo 'SELECT 1;' | bash "$here/psql.sh" databases pg-1)
expected=$(cat <<'EOF'
{
  "args": "exec -i -n databases pg-1 -c postgres -- psql -XAtq -v ON_ERROR_STOP=1 -U postgres -d host=/controller/run hostaddr='' port=5432 dbname=postgres",
  "sql": "SELECT 1;"
}
EOF
)
same "runs only psql in the pod, as postgres on the socket, with the SQL on stdin" "$expected" "$actual"

# The PG* variables of a container do not move the connection off the
# socket: a local psql with the same arguments tries CNPG's socket, which is
# not here, even with PGHOSTADDR, PGHOST and PGPORT set.
psql_output=$(mktemp)
trap 'rm -f "$psql_output"' EXIT
export psql_output
kubectl() {
  shift 8 # exec -i -n databases pg-1 -c postgres --
  if PGHOSTADDR=127.0.0.1 PGHOST=elsewhere PGPORT=6543 PGCONNECT_TIMEOUT=2 "$@" >"$psql_output" 2>&1; then
    return 1
  fi
  echo '{}'
}
export -f kubectl
echo 'SELECT 1;' | bash "$here/psql.sh" databases pg-1 >/dev/null
same_text "PG* variables of the container leave the socket in place" \
  'psql: error: connection to server on socket "/controller/run/.s.PGSQL.5432" failed: No such file or directory' \
  "$(head -1 "$psql_output")"

kubectl() { echo 'not json'; }
export -f kubectl
if echo 'SELECT 1;' | bash "$here/psql.sh" databases pg-1 >/dev/null 2>&1; then
  fail "output that is not JSON fails"
else
  pass "output that is not JSON fails"
fi

kubectl() { return 1; }
export -f kubectl
if echo 'SELECT 1;' | bash "$here/psql.sh" databases pg-1 >/dev/null 2>&1; then
  fail "a failed exec fails"
else
  pass "a failed exec fails"
fi

finish
