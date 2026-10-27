#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

# Answers like psql would, after checking it got postgres.sql on the primary.
kubectl() {
  [[ "$*" == "exec -i -n databases pg-1 -c postgres -- "* ]] || return 1
  grep -q "'can_log_in'" || return 1
  cat <<'EOF'
{"superusers" : ["postgres"], "can_log_in" : ["orders", "postgres"]}
EOF
}
export -f kubectl

actual=$(bash "$here/postgres.sh" databases pg-1)
expected=$(cat <<'EOF'
{"superusers": ["postgres"], "can_log_in": ["orders", "postgres"]}
EOF
)
same "runs postgres.sql on the primary" "$expected" "$actual"

finish
