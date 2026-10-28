#!/usr/bin/env bash
# Checks TCP results and login status markers with command fixtures.
# Usage: bash run.test.sh
# Exit: 0 all assertions pass, 1 an assertion fails, nonzero on a test error.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

timeout() {
  case ${!#} in
    443) return 0 ;;
    5432) return 124 ;;
    8000) echo 'bash: Connection refused' >&2; return 2 ;;
    *) echo 'bash: command missing' >&2; return 127 ;;
  esac
}
psql() { echo 'FATAL: pg_hba.conf rejects connection' >&2; return 2; }
export -f timeout psql
actual=$(bash "$here/run.sh" 10.43.0.1:443 10.42.0.1:5432 10.42.0.1:8000 'lb 192.0.2.1:5432' 'lb 192.0.2.1:5433')
expected=$(cat <<'TEXT'
10.43.0.1:443 connected
10.42.0.1:5432 timeout
10.42.0.1:8000 Connection refused
lb 192.0.2.1:5432 FATAL: pg_hba.conf rejects connection 
lb 192.0.2.1:5433 FATAL: pg_hba.conf rejects connection 
TEXT
)
same_text 'pod TCP and login attempts' "$expected" "$actual"
psql() { echo 'pg_hba.conf rejects connection'; }
export -f psql
same_text 'successful login stays distinguishable from denial' \
  'lb 192.0.2.1:5432 succeeded: pg_hba.conf rejects connection ' \
  "$(bash "$here/run.sh" 'lb 192.0.2.1:5432')"
psql() { [[ -z ${PGHOST-} && $PGCONNECT_TIMEOUT == 3 ]] && echo 1; }
export -f psql
same_text 'no PG* variable of the image reaches psql' 'lb 192.0.2.1:5432 succeeded: 1 ' \
  "$(PGHOST=203.0.113.9 PGCONNECT_TIMEOUT=60 bash "$here/run.sh" 'lb 192.0.2.1:5432')"
finish
