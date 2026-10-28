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
    pairs=(01-accounts 02-login-rules 03-client-ca 04-encryption 05-network
      06-container-isolation 07-operator-secrets 08-platform-pods 09-platform-secrets
      10-platform-setup 11-platform-nodes-certificates)
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
    echo "evidence-12-versions-actual.png"
  fi
} | LC_ALL=C sort
