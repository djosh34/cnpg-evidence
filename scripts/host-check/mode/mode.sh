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
if [[ ! -e $path ]]; then
  add_check "$id" false missing "$path missing"
  exit 0
fi
mode_owner=$(stat -c '%a %U:%G' "$path")
read -r mode owner <<<"$mode_owner"
# Reads the ACL marker from ls output.
# shellcheck disable=SC2012
acl=$(ls -ld "$path" | cut -c11)
# The value names a mode as the rule does when it is tight enough, so every
# passing path has the same value.
mode_value=$mode
(((8#$mode & ~8#$max) != 0)) || mode_value="$max or tighter"
acl_value="no ACL"
[[ $acl != + ]] || acl_value=ACL
value="$mode_value, $owner, $acl_value"
ok=false
[[ $value != "$max or tighter, root:root, no ACL" ]] || ok=true
add_check "$id" "$ok" "$value" "$path $mode $owner$([[ $acl == + ]] && echo ' with ACL')"
