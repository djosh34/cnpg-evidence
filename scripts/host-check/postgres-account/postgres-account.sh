#!/usr/bin/env bash
# Checks PostgreSQL host accounts; lists group members, sudoers and packages.
# Usage: postgres-account.sh UID GID
# Exit: 0 with one JSON check, 2 on NSS query errors; nonzero on other errors.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"
# shellcheck source-path=SCRIPTDIR
source "$here/../accounts/accounts.sh"

postgres_uid=$1
postgres_gid=$2
details=()
open=()
if ! have getent; then
  add_check postgres-account false "getent not found" "getent not found"
  exit 0
fi
accounts=$(postgres_accounts "$postgres_uid" "$postgres_gid") || exit 2
for name in $accounts; do
  line=$(account_state "$name") || open+=("$name")
  details+=("$line")
done
((${#details[@]})) || details=("no account with uid $postgres_uid or primary gid $postgres_gid")
groups=$(postgres_groups "$postgres_gid") || exit 2
if [[ -z $groups ]]; then
  details+=("no group with gid $postgres_gid")
else
  for group in $groups; do
    members=${group##*:}
    details+=("group ${group%%:*} gid=$postgres_gid members=${members:-none}")
  done
fi
sudoers=$(bash "$here/../postgres-sudoers/postgres-sudoers.sh" "$postgres_uid" "$postgres_gid")
details+=("sudoers: $(jq -r .raw <<<"$sudoers")")
if have rpm; then
  pkgs=$(rpm -qa 'postgresql*-server' | sort)
  if [[ -n $pkgs ]]; then
    details+=("postgresql*-server packages: ${pkgs//$'\n'/; }")
  else
    details+=("no postgresql*-server package installed")
  fi
else
  details+=("rpm not found")
fi
ok=true
((${#open[@]} == 0)) || ok=false
add_check postgres-account "$ok" "$(listed "not locked with nologin" "${open[@]}")" "$(joined "${details[@]}")"
