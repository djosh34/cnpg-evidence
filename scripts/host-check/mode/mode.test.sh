#!/usr/bin/env bash
# Tests ownership-mode checks, ACL markers and missing paths.
# Usage: bash mode.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

stat() { echo '700 root:root'; }
ls() { echo 'drwx------ 1 root root'; }
export -f stat ls
same "tight root directory" '{"id":"example","ok":true,"detail":"/usr 700 root:root, want 700 or tighter, root:root, no ACL"}' "$(bash "$here/mode.sh" example /usr 700)"
stat() { echo '755 root:root'; }
export -f stat
same "loose mode" false "$(bash "$here/mode.sh" example /usr 700 | jq .ok)"
stat() { echo '700 root:root'; }
ls() { echo 'drwx------+ 1 root root'; }
export -f stat ls
same "ACL fails" false "$(bash "$here/mode.sh" example /usr 700 | jq .ok)"
same "missing path" '{"id":"example","ok":false,"detail":"/no-such-cnpg-path missing"}' "$(bash "$here/mode.sh" example /no-such-cnpg-path 700)"

finish
