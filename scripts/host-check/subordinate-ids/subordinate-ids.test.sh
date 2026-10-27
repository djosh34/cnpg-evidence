#!/usr/bin/env bash
# Tests default and explicit kubelet ranges, malformed entries and absent files.
# Usage: bash subordinate-ids.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

getent() {
  [[ ${kubelet_available:-false} == true ]] || return 2
  echo 'kubelet:x:1000:1000::/:/sbin/nologin'
}
getsubids() { :; }
# Every file read holds $subids.
awk() { builtin command awk "${@:1:$#-1}" <<<"$subids"; }
export -f getent getsubids awk
export subids=$'kubelet:65536:65536\nalice:200000:65536'
actual=$(bash "$here/subordinate-ids.sh" "$here/subordinate-ids.test.sh" "$here/subordinate-ids.sh")
same "default range overlaps alice" false "$(jq .ok <<<"$actual")"
export kubelet_available=true
actual=$(bash "$here/subordinate-ids.sh" "$here/subordinate-ids.test.sh" "$here/subordinate-ids.sh")
same "explicit kubelet range excludes alice" true "$(jq .ok <<<"$actual")"
subids=$'kubelet:65536:65536\ninvalid-line'
actual=$(bash "$here/subordinate-ids.sh" "$here/subordinate-ids.test.sh" "$here/subordinate-ids.sh")
same "malformed entry fails" false "$(jq .ok <<<"$actual")"
subids=$'kubelet:bad:65536\nalice:200000:65536'
actual=$(bash "$here/subordinate-ids.sh" "$here/subordinate-ids.test.sh" "$here/subordinate-ids.sh")
same "malformed kubelet entry fails" false "$(jq .ok <<<"$actual")"
same_text "malformed kubelet entry named" \
  "malformed or overlapping entries, kubelet range ($here/subordinate-ids.test.sh none; $here/subordinate-ids.sh none): $here/subordinate-ids.test.sh: kubelet:bad:65536; $here/subordinate-ids.sh: kubelet:bad:65536" \
  "$(jq -r .detail <<<"$actual")"
subids=$'kubelet:65536:0\nalice:200000:65536'
actual=$(bash "$here/subordinate-ids.sh" "$here/subordinate-ids.test.sh" "$here/subordinate-ids.sh")
same "empty kubelet range fails" false "$(jq .ok <<<"$actual")"
subids=$'kubelet:9223372036854775807:2\nalice:200000:65536'
actual=$(bash "$here/subordinate-ids.sh" "$here/subordinate-ids.test.sh" "$here/subordinate-ids.sh")
same "kubelet range beyond 2^32 fails" false "$(jq .ok <<<"$actual")"
subids=$'kubelet:65536:65536\nkubelet:bad:65536'
actual=$(bash "$here/subordinate-ids.sh" "$here/subordinate-ids.test.sh" "$here/subordinate-ids.sh")
same "second malformed kubelet entry fails" false "$(jq .ok <<<"$actual")"
export kubelet_available=false
subids=$'kubelet:bad:65536'
actual=$(bash "$here/subordinate-ids.sh" "$here/subordinate-ids.test.sh" "$here/subordinate-ids.sh")
same "malformed kubelet entry fails without the account" false "$(jq .ok <<<"$actual")"
same "absent files pass" true "$(bash "$here/subordinate-ids.sh" /no-such-subuid /no-such-subgid | jq .ok)"

finish
