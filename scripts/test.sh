#!/usr/bin/env bash
# Runs every *.test.sh under scripts/, or under the directories of scripts/
# given as arguments. Exit 0 when all pass, 1 when one fails.
#
# Usage: bash scripts/test.sh [evidence|host-check|prove|desired|lib ...]
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

dirs=()
for d in "$@"; do
  if [[ ! -d $here/$d ]]; then
    echo "test.sh: no directory scripts/$d" >&2
    exit 1
  fi
  dirs+=("$here/$d")
done
if ((${#dirs[@]} == 0)); then
  dirs=("$here")
fi

failed=()
while IFS= read -r test_file; do
  echo "== ${test_file#"$here"/}"
  bash "$test_file" || failed+=("$test_file")
done < <(find "${dirs[@]}" -name '*.test.sh' | sort)

if ((${#failed[@]} > 0)); then
  echo "failed: ${failed[*]}" >&2
  exit 1
fi
echo "all tests passed"
