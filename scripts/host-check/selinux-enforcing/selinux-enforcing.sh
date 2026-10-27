#!/usr/bin/env bash
# Reads the kernel SELinux mode and checks whether it is enforcing.
# Usage: selinux-enforcing.sh [mode|check [ENFORCE_FILE]]
# Exit: 0 with a mode or JSON check (including a failed check), nonzero on errors.
set -euo pipefail
shopt -s inherit_errexit nullglob

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"

path=${2:-/sys/fs/selinux/enforce}
if [[ ! -e $path ]]; then
  mode=disabled raw="$path missing"
else
  enforce=$(< "$path")
  raw="$path = $enforce"
  if [[ $enforce == 1 ]]; then mode=enforcing; else mode=permissive; fi
fi

if [[ ${1:-} == mode ]]; then
  echo "$mode"
else
  add_check selinux-enforcing "$([[ $mode == enforcing ]] && echo true || echo false)" "$mode" "$raw"
fi
