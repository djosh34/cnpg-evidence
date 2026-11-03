#!/usr/bin/env bash
# pgfallback from outside the cluster during kubectl drain of the primary's
# node: see live/pgfallback.sh.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

EVENT='drain'
# shellcheck source=live/pgfallback.sh
. "$LIVE_DIR/pgfallback.sh"
