#!/usr/bin/env bash
# Tests the collected JSON shape and null values.
# Usage: bash collected.jq.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

actual=$(jq -n --arg hostname node --arg os Linux --arg kernel test \
  --arg k3s '' --arg containerd '' --arg selinux disabled --arg containerd_selinux '' \
  --arg postgres_uid 26 --arg postgres_gid 27 \
  --slurpfile listening_tcp <(echo null) --slurpfile missing_tools <(echo '["getcap"]') \
  -f "$here/collected.jq")
expected=$(cat <<'JSON'
{"hostname":"node","os":"Linux","kernel":"test","k3s_version":null,"containerd_version":null,"selinux":"disabled","containerd_enable_selinux":null,"postgres_uid":26,"postgres_gid":27,"listening_tcp":null,"missing_tools":["getcap"]}
JSON
)
same "collected shape and nulls" "$expected" "$actual"

finish
