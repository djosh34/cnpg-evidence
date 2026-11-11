#!/usr/bin/env bash
# Runs one scenario of samples/features on a new three-node k3s cluster, in
# one privileged container that go test builds from this checkout and
# removes at the end. The run's files land in results/. Exit code 0 means
# the scenario passed. Needs docker, bash and Go.
#
# Usage: ./e2e.sh <scenario>
#
# Without a scenario, it lists the scenarios and exits with 2.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if (($# != 1)); then
  echo "usage: ./e2e.sh <scenario>, one of:" >&2
  grep -ho '^ *@[a-z0-9-]*' samples/features/*.feature | tr -d ' @' | grep -vx always | sort
  exit 2
fi
exec go -C e2e test -run '^TestScenario$' -count=1 -timeout 90m -v . -scenario "$1"
