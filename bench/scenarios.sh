#!/usr/bin/env bash
# Prints the tag of every scenario of the feature files in samples/features,
# without the @, one per line, sorted. always.feature's tag is on its
# Feature line, not on a scenario, so it is not one of them.
#
# Usage: bash bench/scenarios.sh
set -euo pipefail
shopt -s inherit_errexit

features=$(cd "$(dirname "${BASH_SOURCE[0]}")/../samples/features" && pwd)
awk '
  /^[[:space:]]*@/ { tags = tags " " $0; next }
  /^[[:space:]]*Scenario/ { print tags }
  { tags = "" }
' "$features"/*.feature | tr -s ' \t' '\n' | sed -n 's/^@//p' | sort
