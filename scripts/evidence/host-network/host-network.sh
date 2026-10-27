#!/usr/bin/env bash
# The host_network_pods_that_can_bind_low_ports fact, from every pod in the
# cluster.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

kubectl get pods --all-namespaces -o json |
  jq .items |
  jq -f "$here/host-network.jq"
