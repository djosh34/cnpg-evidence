#!/usr/bin/env bash
# Runs scripts/host-check/host-check.sh as root on a k3s server node in
# docker, the node live/up.sh starts, and fails unless the checks that fail
# are exactly the known failures of a container node in docs/host-check.md,
# each with the value listed there.
#
# The k3s image has neither bash nor jq, so the script copies in a static
# bash, $BASH_STATIC (default /bin/bash-static, from Ubuntu's bash-static
# package), and the static jq 1.7.1 release, checked by SHA-256.
#
# Needs docker, curl, jq and an x86_64 host, and no container named
# host-check-node.
#
# Usage: bash live/host-check.sh
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NODE=host-check-node
BASH_STATIC=${BASH_STATIC:-/bin/bash-static}
JQ_URL=https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64
JQ_SHA256=5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5
OUT=$LIVE_WORK/host-check
# /tmp is a tmpfs in the node, which docker cp does not reach.
DIR=/opt/cnpg-evidence

[[ $(uname -m) == x86_64 ]] || fail "the static jq here is for x86_64, not $(uname -m)"
[[ -x $BASH_STATIC ]] || fail "no static bash at $BASH_STATIC"
mkdir -p "$OUT"

# The known failures: the rows of the table under "Known failures on
# container nodes" in docs/host-check.md, as [{id, value}] sorted by id.
known_failures() {
  awk '/^## Known failures on container nodes/ {on = 1; next} on && /^## / {exit} on' "$REPO/docs/host-check.md" |
    awk -F' [|] ' '/^[|] `/ {print $1 "\t" $2}' |
    sed 's/^| //; s/`//g' |
    jq -R 'split("\t") | {id: .[0], value: .[1]}' | jq -sc 'sort_by(.id)'
}

node_ready() {
  [[ $(docker exec "$NODE" kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') == True ]]
}

# The network policy controller can add its chains after the node is Ready.
netpol_chains() {
  [[ $(docker exec "$NODE" iptables-save -t filter) == *"-j KUBE-ROUTER-OUTPUT"* ]]
}

want=$(known_failures)
[[ $want != "[]" ]] || fail "no known failures found in docs/host-check.md"

log "jq"
curl -fsSL --max-time 120 -o "$OUT/jq" "$JQ_URL"
echo "$JQ_SHA256  $OUT/jq" | sha256sum -c --quiet -
chmod +x "$OUT/jq"

log "starting k3s in $NODE"
timeout 600 docker pull -q "$K3S_IMAGE" >/dev/null
# As live/up.sh starts its nodes; the volume keeps containerd's files off
# docker's overlayfs.
docker run -d --name "$NODE" --hostname "$NODE" \
  --privileged --tmpfs /run --tmpfs /var/run --tmpfs /tmp \
  -v /var/lib/rancher/k3s \
  "$K3S_IMAGE" server >/dev/null
wait_for 300 "node $NODE Ready" node_ready
wait_for 120 "the network policy controller's chains" netpol_chains

log "host-check.sh on $NODE"
docker exec "$NODE" mkdir -p "$DIR/scripts"
docker cp -q "$BASH_STATIC" "$NODE:/bin/bash"
docker cp -q "$OUT/jq" "$NODE:/bin/jq"
docker cp -q "$REPO/scripts/host-check" "$NODE:$DIR/scripts/host-check"
docker cp -q "$REPO/scripts/lib" "$NODE:$DIR/scripts/lib"
status=0
docker exec "$NODE" bash "$DIR/scripts/host-check/host-check.sh" --node "$NODE" >"$OUT/host-check.json" || status=$?
case $status in
  0 | 1) ;;
  *) fail "host-check.sh failed with exit code $status" ;;
esac
jq . "$OUT/host-check.json"

got=$(jq -c '[.checks[] | select(.ok | not) | {id, value}] | sort_by(.id)' "$OUT/host-check.json")
[[ $got == "$want" ]] || fail "the failed checks are $got, docs/host-check.md lists $want"
log "only the known failures: $got"
