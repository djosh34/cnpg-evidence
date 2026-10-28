#!/usr/bin/env bash
# Checks the kernel SELinux mode and containerd setting, and lists k3s flags.
# Usage: selinux.sh [mode|check [ENFORCE_FILE]] <collected.json
# Exit: 0 with a mode or JSON check, nonzero on collection errors.
set -euo pipefail
shopt -s inherit_errexit

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
  exit 0
fi
facts=$(< /dev/stdin)
enabled=$(jq -r '.containerd_enable_selinux // ""' <<<"$facts")
config=$(bash "$here/../k3s-config/k3s-config.sh")
lines=$(jq -r '[.[][] | select(test("selinux"))] | join("; ")' <<<"$config")
ok=false
value="$mode; enable_selinux ${enabled:-unset}"
if [[ $mode == enforcing && $enabled == true ]]; then
  ok=true value='enforcing, enable_selinux true'
fi
add_check selinux "$ok" "$value" \
  "$raw; enable_selinux = ${enabled:-unset} in the k3s containerd config; config: ${lines:-no selinux setting}"
