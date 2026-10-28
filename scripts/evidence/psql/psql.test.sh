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
  "args": "exec -i -n databases pg-1 -c postgres -- env -i psql -XAtq -v ON_ERROR_STOP=1 -h /controller/run -p 5432 -U postgres -d postgres",
  "sql": "SELECT 1;"
}
EOF
)
same "runs psql in the pod with an empty environment, as postgres on the socket, with the SQL on stdin" "$expected" "$actual"

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
