#!/usr/bin/env bash
# The network_policy section, from the NetworkPolicies in the cluster's
# namespace, the labels of every instance pod and every node's pod range.
#
# Usage: network.sh NAMESPACE CLUSTER LOAD_BALANCER OPERATOR_NAMESPACE OTEL_NAMESPACE
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

namespace=$1
cluster=$2
load_balancer=$3
operator_namespace=$4
otel_namespace=$5

policies=$(kubectl get networkpolicies -n "$namespace" -o json)

pods=$(
  kubectl get pods -n "$namespace" -l "cnpg.io/cluster=$cluster,cnpg.io/podRole=instance" -o json |
    jq -c 'if .items == [] then error("no instance pods") else .items | map({key: .metadata.name, value: .metadata.labels}) | from_entries end'
)

node_pod_cidrs=$(kubectl get nodes -o json | jq -c '[.items[].spec.podCIDR]')

jq -n \
  --slurpfile policies <(echo "$policies") \
  --slurpfile pods <(echo "$pods") \
  --slurpfile node_pod_cidrs <(echo "$node_pod_cidrs") \
  --arg namespace "$namespace" \
  --arg cluster "$cluster" \
  --arg load_balancer "$load_balancer" \
  --arg operator_namespace "$operator_namespace" \
  --arg otel_namespace "$otel_namespace" \
  '{policies: $policies[0].items, pods: $pods[0], node_pod_cidrs: $node_pod_cidrs[0],
    $namespace, $cluster, $load_balancer, $operator_namespace, $otel_namespace}' |
  jq -f "$here/network.jq"
