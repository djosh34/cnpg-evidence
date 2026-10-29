#!/usr/bin/env bash
# Checks rules.yaml and alertmanager.yaml with promtool and amtool, runs the
# unit tests in rules.test.yaml, and checks that dashboard.json is what
# dashboard.py writes and that its Healthy tile counts what the critical alerts
# see. Needs docker, python3 and yq; pulls the two images below.
#
# Usage: bash samples/monitoring/check.sh
set -euo pipefail
shopt -s inherit_errexit

prometheus=prom/prometheus:v3.7.3@sha256:49214755b6153f90a597adcbff0252cc61069f8ab69ce8411285cd4a560e8038
alertmanager=prom/alertmanager:v0.34.1@sha256:e9733bafb1bdef9b00e25a21f8f99dc26a22224bf16641ad754d1649f4c3357a

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

tmp=$(mktemp -d)
chmod 0755 "$tmp"  # the containers read it as another user
trap 'rm -rf "$tmp"' EXIT

promtool() { docker run --rm -v "$here:/w:ro" -v "$tmp:/t:ro" -w /w --entrypoint promtool "$prometheus" "$@"; }
amtool() { docker run --rm -v "$here:/w:ro" -w /w --entrypoint amtool "$alertmanager" "$@"; }

promtool check rules rules.yaml
promtool test rules rules.test.yaml
amtool check-config alertmanager.yaml

# Every alert of rules.yaml reaches the databases receiver.
alerts=$(sed -n 's/^ *- alert: //p' "$here/rules.yaml" | sort -u)
if [ -z "$alerts" ]; then
  echo "check.sh: no alerts found in rules.yaml" >&2
  exit 1
fi
for alert in $alerts; do
  receiver=$(amtool config routes test --config.file=alertmanager.yaml "alertname=$alert")
  if [ "$receiver" != databases ]; then
    echo "check.sh: $alert goes to $receiver, not databases" >&2
    exit 1
  fi
done
echo "ok: every alert goes to the databases receiver"

# dashboard.json is up to date with dashboard.py and rules.yaml.
python3 -I "$here/dashboard.py" --out "$tmp/dashboard.json"
if ! diff -u "$here/dashboard.json" "$tmp/dashboard.json" >/dev/null; then
  echo "check.sh: dashboard.json is out of date; run python3 samples/monitoring/dashboard.py" >&2
  exit 1
fi
echo "ok: dashboard.json is up to date"

# On every case of rules.test.yaml, Healthy counts the critical alerts.
python3 -I "$here/dashboard.py" --healthy-test "$tmp/healthy.test.json" --rules-dir /w
promtool test rules /t/healthy.test.json
