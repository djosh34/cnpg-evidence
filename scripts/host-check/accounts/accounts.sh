#!/usr/bin/env bash
# Reads PostgreSQL host accounts and groups, including direct NSS lookups.
# Usage: source accounts.sh; postgres_accounts UID GID; postgres_groups GID;
#   account_state NAME
# Exit: helpers return 0 on success, account_state 1 for a failed account check,
#   enumeration helpers 2 for a failed NSS query.
set -euo pipefail
shopt -s inherit_errexit nullglob

account_state() {
  local name=$1 entry uid gid shell pw locked=unknown
  entry=$(getent passwd "$name") || {
    echo "$name: no passwd entry"
    return 1
  }
  IFS=: read -r _ _ uid gid _ _ shell <<<"$entry"
  if pw=$(getent shadow "$name"); then
    pw=$(cut -d: -f2 <<<"$pw")
    if [[ $pw == '!'* || $pw == '*'* ]]; then locked=yes; else locked=no; fi
  fi
  echo "$name uid=$uid gid=$gid shell=$shell locked=$locked"
  [[ $locked == yes && ${shell##*/} == nologin ]]
}

postgres_accounts() {
  local postgres_uid=$1 postgres_gid=$2 entries direct status
  entries=$(getent passwd) || return 2
  if direct=$(getent passwd "$postgres_uid"); then
    entries+=$'\n'"$direct"
  else
    status=$?
    [[ $status == 2 ]] || return 2
  fi
  awk -F: -v u="$postgres_uid" -v g="$postgres_gid" \
    '$3 == u || $4 == g {print $1}' <<<"$entries" | sort -u
}

postgres_groups() {
  local postgres_gid=$1 entries direct status
  entries=$(getent group) || return 2
  if direct=$(getent group "$postgres_gid"); then
    entries+=$'\n'"$direct"
  else
    status=$?
    [[ $status == 2 ]] || return 2
  fi
  awk -F: -v g="$postgres_gid" \
    '$3 == g {print $1 ":" $3 ":" $4}' <<<"$entries" | sort -u
}
