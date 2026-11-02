#!/usr/bin/env bash
# Prints the scenarios to run as a JSON list, for the matrix of
# .github/workflows/live.yml. $1 holds scenario names separated by spaces, or
# "all" for every scenario in live/scenarios.txt. Fails on a name that is not
# in that list or has no script in live/scenarios/.
#
# Usage: bash live/plan.sh "all" | bash live/plan.sh "switchover primary-node-loss"
set -euo pipefail
shopt -s inherit_errexit

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mapfile -t known <"$here/scenarios.txt"

read -ra wanted <<<"${1:?usage: plan.sh all|<scenario>...}"
if [[ ${wanted[*]} == all ]]; then
  wanted=("${known[@]}")
fi
for s in "${wanted[@]}"; do
  if ! printf '%s\n' "${known[@]}" | grep -qxF -- "$s"; then
    echo "plan.sh: unknown scenario $s; known: ${known[*]}" >&2
    exit 1
  fi
  if [[ ! -f $here/scenarios/$s.sh ]]; then
    echo "plan.sh: no script live/scenarios/$s.sh" >&2
    exit 1
  fi
done
printf '%s\n' "${wanted[@]}" | sort -u | jq -cRn '[inputs]'
