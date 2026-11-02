#!/usr/bin/env bash
# A primary node loss and a switchover while the object store hangs
# connections: see live/store.sh.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

STORE_MODE=hang
# shellcheck source=live/store.sh
. "$LIVE_DIR/store.sh"
