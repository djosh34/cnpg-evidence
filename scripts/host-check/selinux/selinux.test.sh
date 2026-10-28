#!/usr/bin/env bash
# Tests kernel modes, containerd settings and the listed k3s flags.
# Usage: bash selinux.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

same_text enforcing enforcing "$(bash "$here/selinux.sh" mode /dev/stdin <<<1)"
same_text permissive permissive "$(bash "$here/selinux.sh" mode /dev/stdin <<<0)"
same_text disabled disabled "$(bash "$here/selinux.sh" mode /no-such-selinux-path)"
bash() { echo '{"config":["selinux: true"],"unit":["--selinux"]}'; }
export -f bash
actual=$(/bin/bash "$here/selinux.sh" check /dev/fd/3 3<<<1 <<<'{"containerd_enable_selinux":"true"}')
same "both settings pass" '{"id":"selinux","ok":true,"value":"enforcing, enable_selinux true"}' "$(jq '{id,ok,value}' <<<"$actual")"
same_text "both old raw parts and flags" '/dev/fd/3 = 1; enable_selinux = true in the k3s containerd config; config: selinux: true; --selinux' "$(jq -r .raw <<<"$actual")"
same_text "both differences" 'permissive; enable_selinux unset' "$(/bin/bash "$here/selinux.sh" check /dev/fd/3 3<<<0 <<<'{}' | jq -r .value)"
same "containerd false fails" '{"ok":false,"value":"enforcing; enable_selinux false"}' "$(/bin/bash "$here/selinux.sh" check /dev/fd/3 3<<<1 <<<'{"containerd_enable_selinux":"false"}' | jq '{ok,value}')"
same_text "disabled fails" 'disabled; enable_selinux true' "$(/bin/bash "$here/selinux.sh" check /no-such-selinux-path <<<'{"containerd_enable_selinux":"true"}' | jq -r .value)"

finish
