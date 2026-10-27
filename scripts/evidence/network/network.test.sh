#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

kubectl() {
  case "$*" in
    "get networkpolicies -n databases -o json")
      cat <<'EOF' ;;
{"items": [{"spec": {"podSelector": {"matchLabels": {"cnpg.io/cluster": "pg"}},
  "ingress": [{"from": [{"ipBlock": {"cidr": "10.42.1.0/32"}}], "ports": [{"port": 5432}]}]}}]}
EOF
    "get pods -n databases -l cnpg.io/cluster=pg,cnpg.io/podRole=instance -o json")
      echo '{"items": [{"metadata": {"name": "pg-1", "labels": {"cnpg.io/cluster": "pg"}}}]}' ;;
    "get nodes -o json")
      echo '{"items": [{"spec": {"podCIDR": "10.42.0.0/24"}}, {"spec": {"podCIDR": "10.42.1.0/24"}}]}' ;;
    *) return 1 ;;
  esac
}
export -f kubectl

expected=$(cat <<'EOF'
{"outside": [], "other nodes": [5432], "own node": ["all"], "loadbalancer": [],
 "pg pods": [], "cnpg-system operator": [], "otel": [], "other namespaces": []}
EOF
)
same "reads policies, pod labels and node ranges" \
  "{\"pg-1\": $expected}" "$(bash "$here/network.sh" databases pg pg-rw-lb cnpg-system otel)"

kubectl() {
  case "$*" in
    "get pods "*) echo '{"items": []}' ;;
    *) echo '{"items": []}' ;;
  esac
}
export -f kubectl
if bash "$here/network.sh" databases pg pg-rw-lb cnpg-system otel >/dev/null 2>&1; then
  fail "no instance pod fails"
else
  pass "no instance pod fails"
fi

finish
