#!/usr/bin/env bash
# Collects TCP listeners with process names and pids.
# Usage: listening-tcp.sh
# Exit: 0 with a JSON array (null without ss), nonzero on errors.
set -euo pipefail
shopt -s inherit_errexit nullglob

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"

if have ss; then
  ss -Htlnp | jq -Rn -f "$here/listening-tcp.jq"
else
  echo null
fi
