#!/usr/bin/env bash
# Tests combined directory modes and the failing path list.
# Usage: bash dir-modes.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

stat() { echo '700 root:root'; }
ls() { echo 'drwx------ 1 root root'; }
export -f stat ls
same "both tight paths pass" '{"id":"dir-modes","ok":true,"value":"none"}' \
  "$(bash "$here/dir-modes.sh" /usr /etc | jq '{id,ok,value}')"
stat() { echo '750 root:root'; }
export -f stat
same_text "pod directory allows 750, storage does not" '/usr: 750, root:root, no ACL' \
  "$(bash "$here/dir-modes.sh" /usr /etc | jq -r .value)"
stat() { echo '755 root:root'; }
export -f stat
same_text "both failures joined" '/usr: 755, root:root, no ACL; /etc: 755, root:root, no ACL' \
  "$(bash "$here/dir-modes.sh" /usr /etc | jq -r .value)"
same_text "both missing" '/no-such-storage: missing; /no-such-pods: missing' \
  "$(bash "$here/dir-modes.sh" /no-such-storage /no-such-pods | jq -r .value)"
stat() { echo '700 root:postgres'; }
ls() { echo 'drwx------+ 1 root root'; }
export -f stat ls
same_text "ownership and ACL failures" '/usr: 700 or tighter, root:postgres, ACL; /etc: 750 or tighter, root:postgres, ACL' \
  "$(bash "$here/dir-modes.sh" /usr /etc | jq -r .value)"

finish
