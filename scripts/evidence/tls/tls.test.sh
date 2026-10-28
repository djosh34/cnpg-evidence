#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

# pg-1 runs TLSv1.3 on both; pg-2 has TLS off and plain metrics.
kubectl() {
  local pod=pg-2
  [[ " $* " != *" pg-1 "* ]] || pod=pg-1
  case "$*" in
    "exec -i -n databases "*" -c postgres -- env -i psql "*)
      grep -q "ssl_min_protocol_version" || return 1
      if [[ $pod == pg-1 ]]; then echo '{"ssl": "on", "min_protocol_version": "TLSv1.3"}'
      else echo '{"ssl": "off", "min_protocol_version": "TLSv1.2"}'; fi ;;
    "exec -n databases "*" -c postgres -- sh -c "*"openssl s_client -connect 127.0.0.1:9187"*)
      if [[ $pod == pg-1 ]]; then printf 'CONNECTION ESTABLISHED\nProtocol version: TLSv1.3\n'
      else echo 'error:0A00010B:SSL routines::wrong version number'; fi ;;
    *) return 1 ;;
  esac
}
export -f kubectl

same "per pod: PostgreSQL's lowest TLS version, the metrics port's TLS version" \
  '{"pg-1": {"postgresql": "TLSv1.3", "metrics": "TLSv1.3"}, "pg-2": {"postgresql": "off", "metrics": "none"}}' \
  "$(bash "$here/tls.sh" databases pg-1 pg-2)"

kubectl() { echo 'Error from server (Forbidden)' >&2; return 1; }
export -f kubectl
if bash "$here/tls.sh" databases pg-1 >/dev/null 2>&1; then
  fail "a failed exec fails"
else
  pass "a failed exec fails"
fi

finish
