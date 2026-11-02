#!/usr/bin/env bash
# The evidence scripts against the cluster, as docs/evidence.md and
# docs/prove.md run them: desired.sh for the desired documents, evidence.sh,
# and prove.sh as root on every node, which the runner sees through
# /proc/<pid>/root of the node's container. Fails unless evidence.sh finds no
# violation, every prove attempt has the result of the desired document, and
# the compliance metric is 0 for every check on every instance. Nothing
# fails here, so the event is the scripts' run; with the writer, writes must
# not stop for more than 180 s while they run.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

OUT=$LIVE_WORK/evidence
mkdir -p "$OUT"

wait_for 600 "three ready instances, two streaming replicas" settled
values=$(yq -o=json "$REPO/desired.yaml")
k get secret client-ca -n "$NS" -o jsonpath='{.data.ca\.crt}' | base64 -d >"$OUT/client-ca.pem"
start_client

T0=$(now_ms)
log "desired.sh"
bash "$REPO/scripts/desired/desired.sh" --ca "$OUT/client-ca.pem" <<<"$values" >"$OUT/evidence.desired.json" ||
  fail "desired.sh for evidence failed"
bash "$REPO/scripts/desired/desired.sh" --source prove <<<"$values" >"$OUT/prove.desired.json" ||
  fail "desired.sh for prove failed"

log "evidence.sh"
status=0
bash "$REPO/scripts/evidence/evidence.sh" --ca "$OUT/client-ca.pem" <<<"$values" >"$OUT/evidence.json" || status=$?
case $status in
  0) ;;
  1) fail "evidence.sh found violations: $(jq -c .violations "$OUT/evidence.json")" ;;
  *) fail "evidence.sh failed with exit code $status" ;;
esac
EVIDENCE=$(now_ms)

# Every probe of the desired document, with its value, and no other.
want=$(jq -c '[.probes[] | {probe, value}]' "$OUT/prove.desired.json")
for n in "${NODES[@]}"; do
  log "prove.sh on $n"
  root=/proc/$(docker inspect -f '{{.State.Pid}}' "$n")/root
  status=0
  # shellcheck disable=SC2024 # prove.sh runs as root, its output file is ours
  sudo env "PATH=$PATH" "KUBECONFIG=$KUBECONFIG" \
    bash "$REPO/scripts/prove/prove.sh" --node "$n" --node-root "$root" <<<"$values" >"$OUT/prove.$n.json" || status=$?
  case $status in
    0 | 1) ;;
    *) fail "prove.sh on $n failed with exit code $status" ;;
  esac
  got=$(jq -c '[.probes[] | {probe, value}]' "$OUT/prove.$n.json")
  [[ $status == 0 && $got == "$want" ]] ||
    fail "prove.sh on $n: the attempts $(jq -c '[.probes[] | select(.ok | not) | {probe, raw}]' "$OUT/prove.$n.json"), probes and values $got, wanted $want"
done
PROVE=$(now_ms)

# cnpg_compliance_violations has one series per check; each must be 0.
pods=$(instances | awk '{print $1}')
for pod in $pods; do
  page=$(metrics_of "$pod")
  series=$(awk '/^cnpg_compliance_violations\{/' <<<"$page")
  [[ -n $series && $(wc -l <<<"$series") == 4 ]] || fail "$pod does not export the 4 compliance checks: ${series:-none}"
  [[ -z $(awk '$2 != 0' <<<"$series") ]] || fail "$pod has compliance violations: $(awk '$2 != 0' <<<"$series" | paste -sd ' ')"
done
METRICS=$(now_ms)

wait_back
finish

summary "### evidence, writer $WRITER"
summary ""
row "Seconds after the start of the scripts" ""
summary "|---|---|"
row "evidence.sh: no violations" "$(secs "$EVIDENCE")"
row "prove.sh on ${NODES[*]}: $(jq length <<<"$want") probes each, all as desired" "$(secs "$PROVE")"
row "cnpg_compliance_violations 0 for 4 checks on every instance" "$(secs "$METRICS")"
common_rows
print_summary
