#!/usr/bin/env bash
# Runs every *.test.sh under scripts/. Exit 0 when all pass, 1 when one fails.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

failed=()
while IFS= read -r test_file; do
  echo "== ${test_file#"$here"/}"
  bash "$test_file" || failed+=("$test_file")
done < <(find "$here" -name '*.test.sh' | sort)

if ((${#failed[@]} > 0)); then
  echo "failed: ${failed[*]}" >&2
  exit 1
fi
echo "all tests passed"
