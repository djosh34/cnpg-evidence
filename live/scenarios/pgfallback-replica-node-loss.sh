#!/usr/bin/env bash
# pgfallback from outside the cluster while a replica's node is lost for
# 120 s: see live/pgfallback.sh.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

EVENT='replica-node-loss'
# shellcheck source=live/pgfallback.sh
. "$LIVE_DIR/pgfallback.sh"
