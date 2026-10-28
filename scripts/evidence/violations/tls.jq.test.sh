#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

facts='{"tls": {"pg-1": {"postgresql": "TLSv1.3", "metrics": "TLSv1.3"}, "pg-2": {"postgresql": "TLSv1.3", "metrics": "TLSv1.3"}}}'

# violations FILTER: the sentences for the clean facts changed by a jq filter.
violations() {
  jq -c "{facts: ($1)}" <<<"$facts" | jq -L "$here" -f "$here/tls.jq"
}

same "the clean cluster has none" '[]' "$(violations .)"

same "TLSv1.2 allowed, TLS off, plain metrics" \
  '["rule 1: pod pg-1: PostgreSQL accepts TLS from TLSv1.2, not only TLSv1.3", "rule 1: pod pg-2: PostgreSQL runs without TLS",
    "rule 1: pod pg-2: metrics on 9187 do not use TLS"]' \
  "$(violations '.tls["pg-1"].postgresql = "TLSv1.2" | .tls["pg-2"] = {postgresql: "off", metrics: "none"}')"

finish
