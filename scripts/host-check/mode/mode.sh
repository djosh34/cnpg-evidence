#!/usr/bin/env bash
# Checks a path's mode ceiling, root ownership and ACL marker.
# Usage: mode.sh ID PATH MAX_OCTAL_MODE
# Exit: 0 with one JSON check (including a failed check), nonzero on errors.
set -euo pipefail
shopt -s inherit_errexit nullglob

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"

id=$1
path=$2
max=$3
ok=false
if [[ ! -e $path ]]; then
  add_check "$id" false "$path missing"
  exit 0
fi
mode_owner=$(stat -c '%a %U:%G' "$path")
read -r mode owner <<<"$mode_owner"
# Reads the ACL marker from ls output.
# shellcheck disable=SC2012
acl=$(ls -ld "$path" | cut -c11)
if (((8#$mode & ~8#$max) == 0)) && [[ $owner == root:root && $acl != + ]]; then
  ok=true
fi
add_check "$id" "$ok" "$path $mode $owner$([[ $acl == + ]] && echo ' with ACL'), want $max or tighter, root:root, no ACL"
