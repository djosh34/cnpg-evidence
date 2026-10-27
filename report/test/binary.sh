#!/usr/bin/env bash
# Tests the built cnpg-report binary in a stock ubi9-minimal container with no
# network: it renders every sample, writes exactly the expected images, exits
# 2 with nothing written on a broken document, and opens no OS library or
# font file.
#
# Usage: bash report/test/binary.sh BINARY OUT_DIR
# Needs docker (or podman as docker) and jq. Pulls ubi9-minimal and builds a
# throwaway image with strace, so it needs network itself. Writes the images
# into OUT_DIR/<clean|failing|desired>/<source>/ and the trace summary into
# OUT_DIR/strace-summary.txt.
set -euo pipefail

ubi_minimal=registry.access.redhat.com/ubi9/ubi-minimal@sha256:6f3a78179e0b30b930a186e7f68a4af52e51bb82406c9653be10bddd624e40f5

if [ $# -ne 2 ]; then
  echo "usage: bash report/test/binary.sh BINARY OUT_DIR" >&2
  exit 2
fi
binary=$(realpath "$1")
out=$(realpath -m "$2")
report=$(cd "$(dirname "$0")/.." && pwd)
samples=$report/samples
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Runs IMAGE with no network, the binary as /cnpg-report, the samples in
# /samples, and OUT_DIR and the work directory writable.
offline() {
  local image=$1
  shift
  docker run --rm --network=none --user "$(id -u):$(id -g)" \
    -v "$binary:/cnpg-report:ro" -v "$samples:/samples:ro" \
    -v "$out:/out" -v "$work:/work" "$image" "$@"
}

# check DESCRIPTION COMMAND...: runs the command, counts it as failed if it fails.
failures=0
check() {
  local what=$1
  shift
  if "$@"; then
    echo "ok: $what"
  else
    echo "FAILED: $what"
    failures=$((failures + 1))
  fi
}

# Renders one call and compares the written files with the expected list.
renders() {
  local dir=$1 doc=$2
  shift 2
  offline "$ubi_minimal" /cnpg-report "$@" --out "/out/$dir" "/samples/$doc" &&
    diff <(bash "$report/test/expected-images.sh" "$samples/$doc") <(cd "$out/$dir" && LC_ALL=C ls)
}

# A call that must exit 2 and leave its output directory absent.
refuses() {
  local name=$1 doc=$2 status=0
  offline "$ubi_minimal" /cnpg-report --desired /samples/evidence.desired.json \
    --out "/work/$name" "$doc" || status=$?
  [ "$status" = 2 ] && [ ! -e "$work/$name" ]
}

docker pull -q "$ubi_minimal"
for run in clean failing; do
  for source in evidence host-check prove; do
    check "$source $run sample: every expected image" \
      renders "$run/$source" "$source.$run.json" --desired "/samples/$source.desired.json"
  done
done
for source in evidence prove; do
  check "$source desired sample alone: every desired image" renders "desired/$source" "$source.desired.json"
done

echo '{"kind": "actual",' > "$work/broken.json"
check "broken JSON: exit 2, nothing written" refuses broken /work/broken.json
jq 'del(.tls)' "$samples/evidence.clean.json" > "$work/missing-key.json"
check "missing key: exit 2, nothing written" refuses missing-key /work/missing-key.json

# strace is no part of ubi9-minimal, so a throwaway image adds it while it has
# network. strace loads its own libraries before tracing starts.
printf 'FROM %s\nRUN microdnf install -y strace && microdnf clean all\n' "$ubi_minimal" > "$work/Containerfile"
docker build -q -t cnpg-report-strace -f "$work/Containerfile" "$work" > /dev/null
offline cnpg-report-strace strace -f -qq -e trace=openat -o /work/trace.txt \
  /cnpg-report --desired /samples/evidence.desired.json --out /work/traced /samples/evidence.failing.json
docker rmi -f cnpg-report-strace > /dev/null
os_paths='"(/usr/lib64|/lib64|/usr/share/fonts|/etc/fonts)/'
{
  echo "openat calls: $(grep -c 'openat(' "$work/trace.txt")"
  echo "processes: $(cut -d' ' -f1 "$work/trace.txt" | sort -u | wc -l)"
  echo "under /usr/lib64, /lib64, /usr/share/fonts or /etc/fonts: $(grep -cE "$os_paths" "$work/trace.txt" || [ $? = 1 ])"
  grep -E "$os_paths" "$work/trace.txt" || [ $? = 1 ]
  echo "absolute paths opened outside the unpacked payload:"
  grep -oE 'openat\([^,]*, "/[^"]*"' "$work/trace.txt" | sed 's/^[^"]*"//; s/"$//' |
    grep -vE '^/tmp/cnpg-report-' | sort | uniq -c | sort -rn
} > "$out/strace-summary.txt"
head -n 3 "$out/strace-summary.txt"
check "no open under /usr/lib64, /lib64, /usr/share/fonts or /etc/fonts" \
  test "$(grep -cE "$os_paths" "$work/trace.txt" || [ $? = 1 ])" = 0

if [ "$failures" -gt 0 ]; then
  echo "$failures checks failed" >&2
  exit 1
fi
echo "all checks passed"
