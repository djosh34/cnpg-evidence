#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

# kubectl and openssl are scripts in $bin, since tls.sh runs kubectl
# port-forward with exec. pg-1 runs TLSv1.3 on both; pg-2 has TLS off and
# plain metrics. Every exec is logged, and only psql is answered: the
# instance image has no openssl.
bin=$(mktemp -d)
trap 'rm -rf "$bin"' EXIT
export EXEC_LOG=$bin/exec.log FORWARD_PID=$bin/forward.pid
cat >"$bin/kubectl" <<'SH'
#!/usr/bin/env bash
pod=pg-2
[[ " $* " != *" pg-1 "* && " $* " != *" pod/pg-1 "* ]] || pod=pg-1
case "$*" in
  "exec -i -n databases "*" -c postgres -- psql "*)
    echo "$*" >>"$EXEC_LOG"
    grep -q "ssl_min_protocol_version" || exit 1
    if [[ $pod == pg-1 ]]; then echo '{"ssl": "on", "min_protocol_version": "TLSv1.3"}'
    else echo '{"ssl": "off", "min_protocol_version": "TLSv1.2"}'; fi ;;
  "exec "*)
    echo "$*" >>"$EXEC_LOG"
    echo 'exec: "openssl": executable file not found in $PATH' >&2
    exit 127 ;;
  "port-forward -n databases pod/$pod :9187")
    [[ ${FORWARD:-} != fails ]] || { echo 'error: unable to forward port because pod is not running'; exit 1; }
    [[ $pod == pg-1 ]] && echo 'Forwarding from 127.0.0.1:41001 -> 9187' || echo 'Forwarding from 127.0.0.1:41002 -> 9187'
    echo $$ >"$FORWARD_PID"
    exec sleep 60 ;;
  *) exit 1 ;;
esac
SH
cat >"$bin/openssl" <<'SH'
#!/usr/bin/env bash
[[ ${HANDSHAKE:-} != hangs ]] || exit 124 # what timeout returns
case "$*" in
  "s_client -connect 127.0.0.1:41001 -brief") printf 'CONNECTION ESTABLISHED\nProtocol version: TLSv1.3\n' >&2 ;;
  "s_client -connect 127.0.0.1:41002 -brief") echo 'error:0A00010B:SSL routines::wrong version number' >&2; exit 1 ;;
  *) exit 2 ;;
esac
SH
chmod +x "$bin/kubectl" "$bin/openssl"
path=$PATH

PATH=$bin:$path
same "per pod: PostgreSQL's lowest TLS version, the metrics port's TLS version through a local openssl" \
  '{"pg-1": {"postgresql": "TLSv1.3", "metrics": "TLSv1.3"}, "pg-2": {"postgresql": "off", "metrics": "none"}}' \
  "$(bash "$here/tls.sh" databases pg-1 pg-2)"
same_text "the only exec into an instance runs psql" 2 "$(grep -c -- '-c postgres -- psql -XAtq ' "$EXEC_LOG")"
same_text "no other exec" 2 "$(wc -l <"$EXEC_LOG")"

# The old check ran openssl in the pod, and an image without openssl read as
# "metrics: none", a TLS violation. Now a missing openssl is a collection error
# that names it, with nothing on stdout.
tools=$(mktemp -d)
for tool in dirname jq sed timeout sleep grep; do
  ln -s "$(command -v "$tool")" "$tools/$tool"
done
ln -s "$bin/kubectl" "$tools/kubectl"
status=0
output=$(PATH=$tools "$BASH" "$here/tls.sh" databases pg-1 2>"$bin/err") || status=$?
rm -rf "$tools"
same_text "a missing local openssl exits 2" 2 "$status"
same_text "and prints nothing" "" "$output"
same_text "and names the tool" "tls.sh: error: openssl not found" "$(cat "$bin/err")"

status=0
output=$(FORWARD=fails bash "$here/tls.sh" databases pg-1 2>"$bin/err") || status=$?
same_text "a port-forward that does not start exits 2" 2 "$status"
same_text "with kubectl's error" \
  "tls.sh: error: port-forward to pg-1:9187 did not start: error: unable to forward port because pod is not running" \
  "$(cat "$bin/err")"

status=0
output=$(HANDSHAKE=hangs bash "$here/tls.sh" databases pg-1 2>"$bin/err") || status=$?
same_text "a handshake that hangs exits 2" 2 "$status"
same_text "and says so" "tls.sh: error: TLS handshake with pg-1:9187 timed out" "$(cat "$bin/err")"
if kill -0 "$(cat "$FORWARD_PID")" 2>/dev/null; then
  fail "and stops the port-forward"
else
  pass "and stops the port-forward"
fi

cat >"$bin/kubectl" <<'SH'
#!/usr/bin/env bash
echo 'Error from server (Forbidden)' >&2
exit 1
SH
if bash "$here/tls.sh" databases pg-1 >/dev/null 2>&1; then
  fail "a failed exec fails"
else
  pass "a failed exec fails"
fi

finish
