#!/usr/bin/env bash
# Fails unless commit $1 has a successful run of .github/workflows/bench.yml
# for every scenario of bench/scenarios.sh. A successful run passed each of
# its scenarios on amd64 and on arm64. Reads the scenarios of a run from its
# name, "bench: <scenarios>", which the workflow sets from its input; "all"
# is every scenario. Runs on the commit's checkout.
#
# Needs gh with a token that may read the repository's actions, and jq.
#
# Usage: bash bench/release-check.sh <commit sha>
set -euo pipefail
shopt -s inherit_errexit

sha=${1:?usage: release-check.sh <commit sha>}
repo=${GITHUB_REPOSITORY:-djosh34/cnpg-evidence}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
scenarios=$(bash "$here/scenarios.sh")

runs=$(gh api --paginate "repos/$repo/actions/workflows/bench.yml/runs?head_sha=$sha&status=success&per_page=100" \
  --jq '.workflow_runs[] | select(.conclusion == "success") | "\(.html_url) \(.name)"')

# Every scenario of each successful run, one per line.
covered=$(
  while read -r url name; do
    [[ -n $url ]] || continue
    if [[ ! $name =~ ^bench:\ (.+)$ ]]; then
      echo "release-check.sh: skipping run $url, its name is not 'bench: <scenarios>': $name" >&2
      continue
    fi
    ran=${BASH_REMATCH[1]}
    if [[ $ran == all ]]; then
      ran=$scenarios
    fi
    echo "release-check.sh: $url ran $(tr -s " " "\n" <<<"$ran" | paste -sd " ")" >&2
    tr -s ' ' '\n' <<<"$ran"
  done <<<"$runs"
)

missing=$(comm -23 <(echo "$scenarios") <(echo "$covered" | sed '/^$/d' | sort -u))
if [[ -n $missing ]]; then
  echo "release-check.sh: commit $sha has no successful bench run of: $(paste -sd " " <<<"$missing")" >&2
  exit 1
fi
echo "release-check.sh: commit $sha has a successful bench run of every scenario, on amd64 and arm64"
