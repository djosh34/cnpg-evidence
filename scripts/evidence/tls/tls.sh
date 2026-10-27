#!/usr/bin/env bash
# The tls section: per instance pod, the lowest TLS version PostgreSQL
# accepts ("off" without TLS), and the TLS version the metrics port 9187
# answers with ("none" when it does not speak TLS). Both are read from the
# running instance: PostgreSQL's settings through psql, the metrics port by
# a TLS handshake with openssl inside the pod.
#
# Usage: tls.sh NAMESPACE POD...
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

namespace=$1
shift

for pod in "$@"; do
  settings=$(bash "$here/../psql/psql.sh" "$namespace" "$pod" <"$here/tls.sql")

  # A failed handshake ends the shell with 0, so only a failed exec fails here.
  handshake=$(
    kubectl exec -n "$namespace" "$pod" -c postgres -- \
      sh -c 'timeout 10 openssl s_client -connect 127.0.0.1:9187 -brief </dev/null 2>&1; exit 0'
  )
  metrics=$(sed -n 's/^Protocol version: //p' <<<"$handshake")

  jq -c --arg pod "$pod" --arg metrics "${metrics:-none}" \
    '{key: $pod, value: {postgresql: (if .ssl == "on" then .min_protocol_version else "off" end), metrics: $metrics}}' \
    <<<"$settings"
done | jq -s from_entries
