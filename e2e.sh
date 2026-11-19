#!/usr/bin/env bash
# Runs one scenario of samples/features on a new three-node k3s cluster, in
# one privileged container that go test builds from this checkout and
# removes at the end. The cluster has the settings of samples/, or of
# variants/<variant> when a variant is given, and every version of the
# manifest versions/<manifest>, versions/latest.yaml when none is given. The
# run's files land in results/. Exit code 0 means the scenario passed.
# Needs docker, bash and Go.
#
# Usage: ./e2e.sh <scenario> [<variant> [<manifest>]]
#
# Without a scenario, it lists the scenarios and exits with 2. An empty
# variant is the samples, as in ./e2e.sh rollout '' v1.34.yaml.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if (($# < 1 || $# > 3)) || [[ -z $1 ]]; then
  echo "usage: ./e2e.sh <scenario> [<variant> [<manifest>]], scenario one of:" >&2
  grep -ho '^ *@[a-z0-9-]*' samples/features/*.feature | tr -d ' @' | grep -vx always | sort
  exit 2
fi
exec go -C e2e test -run '^TestScenario$' -count=1 -timeout 90m -v . -scenario "$1" -variant "${2-}" -manifest "${3-}"
