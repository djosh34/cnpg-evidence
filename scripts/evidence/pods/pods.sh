#!/usr/bin/env bash
# The instance pods of the cluster: the primary, all instances, and those
# that run in the host's user namespace, where uid 26 is postgres on the host.
#
# Usage: pods.sh NAMESPACE CLUSTER
set -euo pipefail
shopt -s inherit_errexit

namespace=$1
cluster=$2

primary=$(kubectl get cluster "$cluster" -n "$namespace" -o jsonpath='{.status.currentPrimary}')

kubectl get pods -n "$namespace" -l "cnpg.io/cluster=$cluster,cnpg.io/podRole=instance" -o json |
  jq --arg primary "$primary" '{
    primary: $primary,
    instances: ([.items[].metadata.name] | sort),
    sharing_host_uids: ([.items[] | select(.spec.hostUsers != false) | .metadata.name] | sort)
  }'
