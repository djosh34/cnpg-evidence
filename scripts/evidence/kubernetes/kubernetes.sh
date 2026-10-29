#!/usr/bin/env bash
# The kubernetes section: who holds which right, as answered by the API
# server for every subject of every RoleBinding and ClusterRoleBinding, and
# in granted_by the reasons, which name the bindings. evidence.sh passes
# granted_by to the violations and leaves it out of the document.
#
# Usage: kubernetes.sh NAMESPACE CLUSTER OPERATOR_NAMESPACE OPERATOR_ACCOUNT PLUGIN_ACCOUNT
#                      CERT_MANAGER_NAMESPACE INSTANCE_POD...
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

namespace=$1
cluster=$2
operator_namespace=$3
operator_account=$4
plugin_account=$5
cert_manager_namespace=$6
shift 6
instance_pods=$(jq -nc '$ARGS.positional' --args "$@")

subjects=$(
  {
    kubectl get rolebindings --all-namespaces -o json
    kubectl get clusterrolebindings -o json
  } | jq -s '[.[].items[]]' | jq -f "$here/subjects.jq"
)

names() { jq -c '[.items[].metadata.name]'; }
namespaces=$(kubectl get namespaces -o json | names)
nodes=$(kubectl get nodes -o json | names)
configmaps=$(kubectl get configmaps -n "$namespace" -o json | names)
secrets=$(
  kubectl get secrets --all-namespaces -o json |
    jq -c '.items | group_by(.metadata.namespace) | map({key: .[0].metadata.namespace, value: map(.metadata.name)}) | from_entries'
)

# Traefik's IngressRoute and IngressRouteTCP exist only where Traefik's CRDs
# are installed.
routes='["ingressroutes.traefik.io", "ingressroutetcps.traefik.io"]'
traefik_resources=$(kubectl api-resources --api-group=traefik.io -o name)
ingress_routes=$(jq -Rnc --argjson routes "$routes" '$routes - ($routes - [inputs])' <<<"$traefik_resources")
not_served=$(jq -nc --argjson routes "$routes" --argjson served "$ingress_routes" '$routes - $served')

needs=$(
  jq -n \
    --slurpfile subjects <(echo "$subjects") \
    --argjson namespaces "$namespaces" \
    --argjson nodes "$nodes" \
    --argjson secrets "$secrets" \
    --argjson configmaps "$configmaps" \
    --argjson instance_pods "$instance_pods" \
    --arg namespace "$namespace" \
    --arg cluster "$cluster" \
    --arg operator_namespace "$operator_namespace" \
    --arg operator_account "$operator_account" \
    --arg plugin_account "$plugin_account" \
    --arg cert_manager_namespace "$cert_manager_namespace" \
    --argjson ingress_routes "$ingress_routes" \
    '$subjects[0] + {
       $namespaces, $nodes, $secrets, $configmaps, $instance_pods, $namespace, $cluster,
       $operator_namespace, $operator_account, $plugin_account, $ingress_routes,
       accounts: [
         {namespace: $namespace, name: $cluster},
         {namespace: $operator_namespace, name: ($operator_account, $plugin_account)},
         {namespace: $cert_manager_namespace, name: "cert-manager"}
       ]
     }' |
    jq -c -f "$here/needs.jq"
)

# Each distinct question once, all in one List of SubjectAccessReviews and
# one kubectl call. A failed review fails the call, so an error is never a "no".
reviews=$(jq -s -f "$here/reviews.jq" <<<"$needs")
if [[ $(jq '.items | length' <<<"$reviews") == 0 ]]; then
  answers=''
else
  answers=$(kubectl create -o json -f - <<<"$reviews" | jq -s -c -f "$here/answers.jq")
fi

jq -n \
  --slurpfile needs <(echo "$needs") \
  --slurpfile answers <(echo "$answers") \
  --argjson not_served "$not_served" \
  '{needs: $needs, answers: $answers, $not_served}' |
  jq -f "$here/kubernetes.jq"
