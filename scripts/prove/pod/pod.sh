#!/usr/bin/env bash
# Runs instance, service and Kubernetes API connection probes in a disposable namespace.
# Usage: pod.sh NAMESPACE CLUSTER LB_SERVICE
# Exit: 0 records collected (including failed probes), 2 collection error.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../probe.sh"

namespace=$1
cluster=$2
lb_service=$3

image=$(kjson "$namespace" cluster "$cluster" | jq -r '.spec.imageName // .status.image')
api=$(kubectl -n default get service kubernetes -o jsonpath='{.spec.clusterIP}'):443
ips=$(kjson "$namespace" pods -l "cnpg.io/cluster=$cluster,cnpg.io/podRole=instance" | jq -r '.items[].status.podIP')
targets=()
for ip in $ips; do
  for port in 5432 8000 9187; do
    targets+=("$ip:$port")
  done
done

service=$(kjson "$namespace" service "$lb_service")
addresses=$(jq -r -f "$here/../login/targets.jq" <<<"$service")
while read -r address; do
  [[ -z $address ]] || targets+=("lb $address")
done <<<"$addresses"
nodeports=$(jq -r '.spec.ports[].nodePort // empty' <<<"$service")
node_ips=$(kubectl get nodes -o json | jq -r '.items[].status.addresses[] | select(.type == "InternalIP") | .address')
for ip in $node_ips; do
  for port in $nodeports; do
    targets+=("nodeport $ip:$port")
  done
done

probe_namespace=prove-$(date +%s)-$$
log "pod probe in namespace $probe_namespace"
kubectl create namespace "$probe_namespace" >/dev/null
pod_script=$(<"$here/run.sh")
if kubectl -n "$probe_namespace" run probe --image="$image" --restart=Never --command -- \
    bash -c "$pod_script" probe "$api" "${targets[@]}" >/dev/null &&
  kubectl -n "$probe_namespace" wait pod/probe --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s >/dev/null &&
  output=$(kubectl -n "$probe_namespace" logs probe); then
  kubectl delete namespace "$probe_namespace" >/dev/null
else
  kubectl delete namespace "$probe_namespace" >/dev/null || log "namespace $probe_namespace could not be deleted"
  die "pod probe failed in namespace $probe_namespace"
fi

for target in "$api" "${targets[@]}"; do
  line=$(grep -Fm1 "$target " <<<"$output") || line="$target no result, the pod did not finish"
  result=${line#"$target "}
  value=error
  if [[ $target == "$api" ]]; then
    [[ $result != connected ]] || value=allowed
    add_probe control-other-namespace "$target" "connected (Kubernetes API, the pod network works)" \
      allowed "$value" "$result"
  elif [[ $target == "lb "* || $target == "nodeport "* ]]; then
    if [[ $result == 'succeeded: '* ]]; then
      value=allowed
    elif [[ $result =~ pg_hba\.conf\ rejects\ connection|[Cc]onnection\ refused|timeout\ expired ]]; then
      value=denied
    fi
    add_probe "other-namespace-${target%% *}" "${target#* }" \
      "pg_hba refusal or no connection (connection refused or connect timeout)" denied "$value" "$result"
  else
    if [[ $result == timeout || $result == *refused* ]]; then
      value=denied
    elif [[ $result == connected ]]; then
      value=allowed
    fi
    add_probe "other-namespace ${target##*:}" "$target" "timeout or connection refused" denied "$value" "$result"
  fi
done
