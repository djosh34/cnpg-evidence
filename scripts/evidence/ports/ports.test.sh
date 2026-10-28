#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

kubectl() {
  case "$*" in
    "get services --all-namespaces -o json")
      echo '{"items": [{"metadata": {"namespace": "databases", "name": "pg-rw"},
                        "spec": {"type": "ClusterIP", "selector": {"cnpg.io/cluster": "pg"}, "ports": [{"port": 5432, "targetPort": 5432}]}}]}' ;;
    "get endpointslices.discovery.k8s.io --all-namespaces -o json")
      echo '{"items": []}' ;;
    "get pods -n databases -l cnpg.io/cluster=pg,cnpg.io/podRole=instance -o json")
      echo '{"items": [{"metadata": {"name": "pg-1", "labels": {"cnpg.io/cluster": "pg"}}, "spec": {"containers": [{}]}}]}' ;;
    *) return 1 ;;
  esac
}
export -f kubectl

same "reads the Services, EndpointSlices and instance pods" \
  '{"services": {"databases/pg-rw": {"type": "ClusterIP", "selector": "cnpg.io/cluster=pg", "traffic_policy": "none", "ports": ["5432 -> 5432"],
                                     "node_ports": [], "health_check_port": "none", "external_ips": []}},
    "host_ports": {"pg-1": []}}' \
  "$(bash "$here/ports.sh" databases pg)"

kubectl() {
  case "$*" in
    "get endpointslices"*) echo 'Error from server (Forbidden)' >&2; return 1 ;;
    *) echo '{"items": []}' ;;
  esac
}
export -f kubectl
if bash "$here/ports.sh" databases pg >/dev/null 2>&1; then
  fail "a forbidden read fails"
else
  pass "a forbidden read fails"
fi

finish
