#!/usr/bin/env bash
# Runs the container example of docs/report.md ("In a container") as it is
# written there, on the evidence samples, and checks the images it writes.
#
# Usage: bash report/test/docker-example.sh VERSION OUT_DIR
# Needs docker and jq, and the image ghcr.io/djosh34/cnpg-report:VERSION
# either local or pullable. Writes the images into OUT_DIR/images/.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: bash report/test/docker-example.sh VERSION OUT_DIR" >&2
  exit 2
fi
version=$1
out=$(realpath -m "$2")
report=$(cd "$(dirname "$0")/.." && pwd)

# The first bash block after the heading.
example=$(awk '/^### In a container$/ { found = 1 } found && /^```bash$/ { block = 1; next } block && /^```$/ { exit } block' \
  "$report/../docs/report.md")
if [ -z "$example" ]; then
  echo "docker-example.sh: no example under \"### In a container\" in docs/report.md" >&2
  exit 1
fi

mkdir -p "$out/report-input"
cp "$report/samples/evidence.clean.json" "$out/report-input/evidence.json"
cp "$report/samples/evidence.desired.json" "$out/report-input/evidence.desired.json"
(cd "$out" && version=$version bash -euo pipefail -c "$example")
diff <(bash "$report/test/expected-images.sh" "$out/report-input/evidence.json") <(cd "$out/images" && LC_ALL=C ls)
echo "ok: the container example wrote every evidence image"
