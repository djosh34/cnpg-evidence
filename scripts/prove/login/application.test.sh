#!/usr/bin/env bash
# Checks selection of the first hostssl cert rule and missing certificate lines.
# Usage: bash application.test.sh
# Exit: 0 all assertions pass, 1 an assertion fails, nonzero on a test error.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

actual=$(jq -f "$here/application.jq" <<'JSON'
{"spec":{"postgresql":{"pg_hba":["host all all all reject","hostssl\torders   orders all cert map=clients","hostssl billing billing all cert"]}}}
JSON
)
expected=$(cat <<'JSON'
"orders orders"
JSON
)
same 'first certificate line with whitespace' "$expected" "$actual"
actual=$(jq -f "$here/application.jq" <<'JSON'
{"spec":{"postgresql":{"pg_hba":["host all all all reject"]}}}
JSON
)
same_text 'no application certificate line' '' "$actual"
finish
