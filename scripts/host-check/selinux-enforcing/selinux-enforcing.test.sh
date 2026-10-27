#!/usr/bin/env bash
# Tests enforcing, permissive and disabled SELinux modes and check output.
# Usage: bash selinux-enforcing.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

same_text "enforcing" enforcing "$(bash "$here/selinux-enforcing.sh" mode /dev/stdin <<<1)"
same_text "permissive" permissive "$(bash "$here/selinux-enforcing.sh" mode /dev/stdin <<<0)"
same "disabled" '{"id":"selinux-enforcing","ok":false,"value":"disabled","raw":"/no-such-selinux-path missing"}' "$(bash "$here/selinux-enforcing.sh" check /no-such-selinux-path)"
same "enforcing check" '{"id":"selinux-enforcing","ok":true,"value":"enforcing","raw":"/dev/stdin = 1"}' "$(bash "$here/selinux-enforcing.sh" check /dev/stdin <<<1)"

finish
