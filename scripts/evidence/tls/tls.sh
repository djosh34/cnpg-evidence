#!/usr/bin/env bash
# The tls section: per instance pod, the lowest TLS version PostgreSQL
# accepts ("off" without TLS), and the TLS version the metrics port 9187
# answers with ("none" when it does not speak TLS). Both are read from the
# running instance: PostgreSQL's settings through psql, the metrics port by
# a TLS handshake with a local openssl through kubectl port-forward. Nothing
# but psql runs in the instance image.
#
# Usage: tls.sh NAMESPACE POD...
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/common.sh"

namespace=$1
shift

for tool in kubectl openssl timeout; do
  have "$tool" || die "$tool not found"
done

# metrics_tls POD: the TLS version port 9187 of POD answers a handshake
# with, or nothing when it does not speak TLS. A port-forward that does not
# start or ends early is a collection error.
metrics_tls() {
  local pod=$1 forward pid line port handshake status=0
  exec {forward}< <(exec kubectl port-forward -n "$namespace" "pod/$pod" :9187 2>&1)
  pid=$!
  # kubectl prints this line once it listens on a free local port.
  if ! read -r -t 30 line <&"$forward" ||
    [[ ! $line =~ ^Forwarding\ from\ 127\.0\.0\.1:([0-9]+)\ -\>\ 9187$ ]]; then
    kill "$pid" 2>/dev/null || true # it may have ended with the error read here
    die "port-forward to $pod:9187 did not start: ${line:-no output in 30 s}"
  fi
  port=${BASH_REMATCH[1]}

  # A failed handshake is the answer "no TLS"; only a hang is an error.
  handshake=$(timeout 10 openssl s_client -connect "127.0.0.1:$port" -brief </dev/null 2>&1) || status=$?
  if ((status == 124)); then
    kill "$pid" 2>/dev/null || true # it may have ended too; the hang is the error
    die "TLS handshake with $pod:9187 timed out"
  fi
  kill "$pid" 2>/dev/null || die "port-forward to $pod:9187 ended early"
  exec {forward}<&-
  sed -n 's/^Protocol version: //p' <<<"$handshake"
}

for pod in "$@"; do
  settings=$(bash "$here/../psql/psql.sh" "$namespace" "$pod" <"$here/tls.sql")
  metrics=$(metrics_tls "$pod")

  jq -c --arg pod "$pod" --arg metrics "${metrics:-none}" \
    '{key: $pod, value: {postgresql: (if .ssl == "on" then .min_protocol_version else "off" end), metrics: $metrics}}' \
    <<<"$settings"
done | jq -s from_entries
