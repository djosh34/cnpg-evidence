#!/usr/bin/env bash
# Searches sudoers lines for literal PostgreSQL names and numeric identities.
# Usage: postgres-sudoers.sh UID GID [FILE...]
#   Without FILE, reads /etc/sudoers and /etc/sudoers.d/*.
# Exit: 0 with one JSON check (including a failed check), 2 on NSS query errors;
#   other nonzero exits mean a command failed.
set -euo pipefail
shopt -s inherit_errexit nullglob

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"
# shellcheck source-path=SCRIPTDIR
source "$here/../accounts/accounts.sh"

postgres_uid=$1
postgres_gid=$2
shift 2
id=postgres-sudoers
accounts=
groups=
if have getent; then
  accounts=$(postgres_accounts "$postgres_uid" "$postgres_gid") || exit 2
  groups=$(postgres_groups "$postgres_gid") || exit 2
fi
names=$({
  printf '%s\n' postgres "#$postgres_uid" "#$postgres_gid" "$accounts"
  cut -d: -f1 <<<"$groups"
} | awk 'NF' | sort -u | paste -sd'|')
re="(^|[^[:alnum:]_.-])($names)([^[:alnum:]_.-]|\$)"
files=("$@")
if ((${#files[@]} == 0)); then
  files=(/etc/sudoers /etc/sudoers.d/*)
  [[ -e ${files[0]} ]] || files=("${files[@]:1}")
fi
if ((${#files[@]} == 0)); then
  add_check "$id" true "no sudoers files"
  exit 0
fi
# A leading # followed by digits names a uid rather than starting a comment.
hits=$(awk -v re="$re" '
  /^[[:space:]]*(#[^0-9]|#$|$)/ {next}
  $0 ~ re {print FILENAME ":" FNR ": " $0}
' "${files[@]}")
if [[ -z $hits ]]; then
  add_check "$id" true "no line names ${names//|/ or } in ${files[*]}"
else
  add_check "$id" false "${hits//$'\n'/; }"
fi
