#!/usr/bin/env bash
# The client_ca section: the Secret the Cluster takes client CAs from, and
# the certificates in its ca.crt.
#
# Usage: client-ca.sh NAMESPACE CLUSTER
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

namespace=$1
cluster=$2

secret=$(kubectl get cluster "$cluster" -n "$namespace" -o jsonpath='{.status.certificates.clientCASecret}')

certificates=$(
  kubectl get secret "$secret" -n "$namespace" -o jsonpath='{.data.ca\.crt}' |
    base64 -d |
    bash "$here/certificates.sh"
)

jq -n --arg secret "$secret" --slurpfile certificates <(echo "$certificates") \
  '{secret: $secret, certificates: $certificates[0]}'
