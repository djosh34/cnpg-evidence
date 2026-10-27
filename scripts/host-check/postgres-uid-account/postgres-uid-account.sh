#!/usr/bin/env bash
# Checks accounts with the PostgreSQL uid or primary gid for locked passwords
# and nologin shells.
# Usage: postgres-uid-account.sh UID GID
# Exit: 0 with one JSON check (including a failed check), 2 on NSS query errors.
set -euo pipefail
shopt -s inherit_errexit nullglob

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"
# shellcheck source-path=SCRIPTDIR
source "$here/../accounts/accounts.sh"

postgres_uid=$1
postgres_gid=$2
id=postgres-uid-account
ok=true
details=()

if ! have getent; then
  add_check "$id" false "getent not found"
  exit 0
fi
accounts=$(postgres_accounts "$postgres_uid" "$postgres_gid") || exit 2
for name in $accounts; do
  line=$(account_state "$name") || ok=false
  details+=("$line")
done
((${#details[@]})) || details=("no account with uid $postgres_uid or primary gid $postgres_gid")
add_check "$id" "$ok" "$(joined "${details[@]}")"
