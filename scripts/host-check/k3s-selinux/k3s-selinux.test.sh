#!/usr/bin/env bash
# Tests containerd SELinux settings and reported k3s flags.
# Usage: bash k3s-selinux.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

same "effective setting" '{"id":"k3s-selinux","ok":true,"detail":"enable_selinux = true in the k3s containerd config; config: selinux: false"}' "$(bash "$here/k3s-selinux.sh" <<<'{"containerd_enable_selinux":"true","k3s_config":{"config":["selinux: false"]}}')"
same "unset" '{"id":"k3s-selinux","ok":false,"detail":"enable_selinux = unset in the k3s containerd config; config: no selinux setting"}' "$(bash "$here/k3s-selinux.sh" <<<'{"containerd_enable_selinux":null,"k3s_config":{}}')"

finish
