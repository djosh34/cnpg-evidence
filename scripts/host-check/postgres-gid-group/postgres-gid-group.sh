#!/usr/bin/env bash
# Checks PostgreSQL supplementary group members for locked, nologin accounts.
# Usage: postgres-gid-group.sh UID GID
# Exit: 0 with one JSON check (including a failed check), 2 on NSS query errors.
set -euo pipefail
shopt -s inherit_errexit nullglob

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"
# shellcheck source-path=SCRIPTDIR
source "$here/../accounts/accounts.sh"

postgres_gid=$2
id=postgres-gid-group
details=()
# Members that are not locked with a nologin shell.
open=()

if ! have getent; then
  add_check "$id" false "getent not found" "getent not found"
  exit 0
fi
groups=$(postgres_groups "$postgres_gid") || exit 2
for group in $groups; do
  members=${group##*:}
  details+=("group ${group%%:*} gid=$postgres_gid members=${members:-none}")
  for name in ${members//,/ }; do
    line=$(account_state "$name") || open+=("$name")
    details+=("member $line")
  done
done
((${#details[@]})) || details=("no group with gid $postgres_gid")
ok=true
((${#open[@]} == 0)) || ok=false
add_check "$id" "$ok" "$(listed "${open[@]}")" "$(joined "${details[@]}")"
