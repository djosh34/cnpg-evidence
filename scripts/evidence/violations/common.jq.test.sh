#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

common() { jq -c -L "$here" "include \"common\"; $1"; }

same "includes" '[true,false]' "$(echo '["a","b"]' | common '[includes("a"), includes("c")]')"
same "extra, once each" '["c"]' "$(echo '["a","c","c"]' | common '[extra(["a","b"])]')"
same "missing" '["b"]' "$(echo '["a","b"]' | common '[missing(["a"])]')"

finish
