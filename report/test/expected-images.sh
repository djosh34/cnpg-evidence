#!/usr/bin/env bash
# Prints, sorted, the image files cnpg-report writes for one document, by the
# list in report/README.md: both images of each pair for an actual document,
# the desired images for a desired document.
#
# Usage: bash expected-images.sh DOC.json
set -euo pipefail

doc=$1
source=$(jq -er '.source' "$doc")
kind=$(jq -er '.kind' "$doc")
case $kind in
  actual) sides=(desired actual) ;;
  desired) sides=(desired) ;;
  *) echo "expected-images.sh: unknown kind $kind" >&2; exit 1 ;;
esac

case $source in
  evidence)
    pairs=(01-accounts 02-certificate-names 03-login-rules 04-client-ca 05-encryption
      06-network 07-container-isolation 08-operator-secrets 09-platform-pods
      10-platform-secrets 11-platform-setup 12-platform-nodes-certificates)
    ;;
  prove)
    pairs=(01-login-attempts 02-other-namespace 03-host-uid)
    ;;
  host-check)
    node=$(jq -er '.node' "$doc")
    mapfile -t checks < <(jq -er '.checks[].id' "$doc")
    pairs=("${checks[@]/#/$node-}")
    ;;
  *) echo "expected-images.sh: unknown source $source" >&2; exit 1 ;;
esac

{
  for pair in "${pairs[@]}"; do
    for side in "${sides[@]}"; do
      echo "$source-$pair-$side.png"
    done
  done
  if [ "$source" = evidence ] && [ "$kind" = actual ]; then
    echo "evidence-13-versions-actual.png"
  fi
} | LC_ALL=C sort
