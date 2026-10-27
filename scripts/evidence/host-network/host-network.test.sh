#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

kubectl() {
  [[ "$*" == "get pods --all-namespaces -o json" ]] || return 1
  cat <<'PODS'
{"items": [{"metadata": {"namespace": "otel", "name": "collector-x"},
            "spec": {"hostNetwork": true, "containers": [{"name": "c"}]}}]}
PODS
}
export -f kubectl

same "reads every pod" '["otel/collector-x"]' "$(bash "$here/host-network.sh")"

finish
