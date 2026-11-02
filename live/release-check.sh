#!/usr/bin/env bash
# Fails unless commit $1 has a successful run of .github/workflows/live.yml
# for every scenario in live/scenarios.txt, once with the writer and once
# without. Reads the scenarios and the writer setting from the run names,
# "live: <scenarios>, writer on|off", which the workflow sets from its inputs.
# Runs on the commit's checkout.
#
# Needs gh with a token that may read the repository's actions, and jq.
#
# Usage: bash live/release-check.sh <commit sha>
set -euo pipefail
shopt -s inherit_errexit

sha=${1:?usage: release-check.sh <commit sha>}
repo=${GITHUB_REPOSITORY:-djosh34/cnpg-evidence}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mapfile -t scenarios <"$here/scenarios.txt"

names=$(gh api --paginate "repos/$repo/actions/workflows/live.yml/runs?head_sha=$sha&status=success&per_page=100" \
  --jq '.workflow_runs[] | select(.conclusion == "success") | "\(.html_url) \(.name)"')

# One "<scenario> <on|off>" line for each scenario of each successful run.
covered=$(
  while read -r url name; do
    [[ -n $url ]] || continue
    if [[ ! $name =~ ^live:\ (.+),\ writer\ (on|off)$ ]]; then
      echo "release-check.sh: skipping run $url, its name is not of the form 'live: <scenarios>, writer on|off': $name" >&2
      continue
    fi
    read -ra ran <<<"${BASH_REMATCH[1]}"
    if [[ ${ran[*]} == all ]]; then
      ran=("${scenarios[@]}")
    fi
    echo "release-check.sh: $url ran ${ran[*]} with the writer ${BASH_REMATCH[2]}" >&2
    printf "%s ${BASH_REMATCH[2]}\n" "${ran[@]}"
  done <<<"$names"
)

missing=()
for s in "${scenarios[@]}"; do
  for writer in on off; do
    grep -qxF "$s $writer" <<<"$covered" || missing+=("$s (writer $writer)")
  done
done
if ((${#missing[@]} > 0)); then
  echo "release-check.sh: commit $sha has no successful live run of: ${missing[*]}" >&2
  exit 1
fi
echo "release-check.sh: commit $sha has a successful live run of every scenario, with and without the writer"
