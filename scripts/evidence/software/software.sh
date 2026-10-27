#!/usr/bin/env bash
# The software section: what was running when the evidence was taken. The
# operator and plugin versions are the tags of their images.
#
# Usage: software.sh NAMESPACE OPERATOR_NAMESPACE PRIMARY_POD
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

namespace=$1
operator_namespace=$2
primary=$3

kubernetes=$(kubectl version -o json | jq -r .serverVersion.gitVersion)

image_tag() {
  kubectl get deployments -n "$operator_namespace" -l "app.kubernetes.io/name=$1" -o json |
    jq -r '[.items[].spec.template.spec.containers[].image | sub("@.*"; "") | split(":")[-1]] | unique | join(" ")'
}
operator=$(image_tag cloudnative-pg)
plugin=$(image_tag plugin-barman-cloud)

postgresql=$(bash "$here/../psql/psql.sh" "$namespace" "$primary" <"$here/version.sql" | jq -r .postgresql)

jq -n \
  --arg kubernetes "$kubernetes" \
  --arg operator "$operator" \
  --arg plugin "$plugin" \
  --arg postgresql "$postgresql" \
  '{kubernetes: $kubernetes, cnpg_operator: $operator, barman_cloud_plugin: $plugin, postgresql: $postgresql}'
