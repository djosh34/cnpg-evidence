#!/usr/bin/env bash
# The ports section, from every Service and EndpointSlice in the cluster and
# the instance pods.
#
# Usage: ports.sh NAMESPACE CLUSTER
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

namespace=$1
cluster=$2

services=$(kubectl get services --all-namespaces -o json)
endpoint_slices=$(kubectl get endpointslices.discovery.k8s.io --all-namespaces -o json)
pods=$(kubectl get pods -n "$namespace" -l "cnpg.io/cluster=$cluster,cnpg.io/podRole=instance" -o json)

jq -n \
  --slurpfile services <(echo "$services") \
  --slurpfile endpoint_slices <(echo "$endpoint_slices") \
  --slurpfile pods <(echo "$pods") \
  --arg namespace "$namespace" \
  '{services: $services[0].items, endpoint_slices: $endpoint_slices[0].items, pods: $pods[0].items, $namespace}' |
  jq -f "$here/ports.jq"
