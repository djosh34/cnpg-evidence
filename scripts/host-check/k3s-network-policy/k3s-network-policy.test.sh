#!/usr/bin/env bash
# Tests network-policy disable-flag detection, including false.
# Usage: bash k3s-network-policy.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

same "no disable flag" '{"id":"k3s-network-policy","ok":true,"detail":"no disable-network-policy flag"}' "$(bash "$here/k3s-network-policy.sh" <<<'{"k3s_config":{}}')"
same "even false flagged" '{"id":"k3s-network-policy","ok":false,"detail":"disable-network-policy: false"}' "$(bash "$here/k3s-network-policy.sh" <<<'{"k3s_config":{"config":["disable-network-policy: false"]}}')"

finish
