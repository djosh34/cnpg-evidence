#!/usr/bin/env bash
# Checks the memory file's type, mode, anonymous name and contents after exec.
# Usage: bash key.test.sh
# Exit: 0 all assertions pass, 1 an assertion fails, nonzero on a test error.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

# shellcheck disable=SC2016
result=$(python3 "$here/key.py" bash -c '
  [[ -f $PGSSLKEY ]] || exit 2
  [[ $(stat -Lc %a "$PGSSLKEY") == 600 ]] || exit 2
  [[ $(readlink "$PGSSLKEY") == /memfd:prove-replication-key* ]] || exit 2
  cat "$PGSSLKEY"
' <<'KEY'
private-key-fixture
KEY
)
same_text 'private regular anonymous key survives exec' private-key-fixture "$result"
finish
