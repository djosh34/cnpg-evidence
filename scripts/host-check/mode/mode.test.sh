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
same "tight root directory" '{"id":"example","ok":true,"value":"700 or tighter, root:root, no ACL","raw":"/usr 700 root:root"}' "$(bash "$here/mode.sh" example /usr 700)"
stat() { echo '755 root:root'; }
export -f stat
same "loose mode" '{"id":"example","ok":false,"value":"755, root:root, no ACL","raw":"/usr 755 root:root"}' "$(bash "$here/mode.sh" example /usr 700)"
stat() { echo '500 root:root'; }
export -f stat
same "a tighter mode has the same value" '{"id":"example","ok":true,"value":"700 or tighter, root:root, no ACL","raw":"/usr 500 root:root"}' "$(bash "$here/mode.sh" example /usr 700)"
stat() { echo '700 root:postgres'; }
export -f stat
same_text "another group" "700 or tighter, root:postgres, no ACL" "$(bash "$here/mode.sh" example /usr 700 | jq -r .value)"
stat() { echo '700 root:root'; }
ls() { echo 'drwx------+ 1 root root'; }
export -f stat ls
same "ACL fails" '{"id":"example","ok":false,"value":"700 or tighter, root:root, ACL","raw":"/usr 700 root:root with ACL"}' "$(bash "$here/mode.sh" example /usr 700)"
same "missing path" '{"id":"example","ok":false,"value":"missing","raw":"/no-such-cnpg-path missing"}' "$(bash "$here/mode.sh" example /no-such-cnpg-path 700)"

finish
