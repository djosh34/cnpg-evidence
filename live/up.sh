#!/usr/bin/env bash
# Starts three k3s nodes in docker and installs the samples on them: an S3
# store (versitygw), cert-manager with a self-signed CA Issuer, the CNPG
# operator and the barman-cloud plugin from samples/charts/cnpg-*, and
# samples/charts/cnpg-cluster as release pg in databases, with
# samples/desired.yaml and live/values.yaml. Every service runs one pod on
# every node, as docs/samples.md says, and the script checks that it does.
# Only local-path-provisioner runs one pod.
#
# Also builds live/client and installs kubectl cnpg into $LIVE_WORK/bin,
# writes a client certificate for orders-app.test into $LIVE_WORK/certs, and
# starts a first backup to the store.
#
# Needs docker, go, helm, kubectl and curl, and an empty docker: no network
# "live" and no containers named k3s-1 to k3s-3 or s3.
#
# Usage: bash live/up.sh
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

S3_IMAGE=versity/versitygw:v1.10.0@sha256:89cad13cc981986ee284cbafea4613f9533ce6fd5f37a2c96c4c4fb8adb3a316
CNPG_PLUGIN_VERSION=1.30.1         # kubectl cnpg
declare -A CNPG_PLUGIN_SHA256=(
  [x86_64]=784bc46f176b24a150d5de84d0691f10ff613b59456af86b1a4868e1bacb9953
  [arm64]=6ffad753bbbf5d353576967233063f2ba0adb843a4e7ef5ff4cb7384b2716d5e
)

SAMPLES=$REPO/samples
S3_BUCKET=example-bucket
S3_USER=example-access-key
S3_PASSWORD=example-secret-key
K3S_TOKEN=example-token

install_tools() {
  mkdir -p "$LIVE_WORK/bin"
  (cd "$LIVE_DIR/client" && go build -o "$LIVE_WORK/bin/client" .)
  local arch file
  arch=$(uname -m)
  [[ $arch == aarch64 ]] && arch=arm64
  file=kubectl-cnpg_${CNPG_PLUGIN_VERSION}_linux_${arch}.tar.gz
  curl -fsSL --max-time 120 -o "$LIVE_WORK/$file" \
    "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v${CNPG_PLUGIN_VERSION}/$file"
  echo "${CNPG_PLUGIN_SHA256[$arch]}  $LIVE_WORK/$file" | sha256sum -c --quiet -
  tar -xzf "$LIVE_WORK/$file" -C "$LIVE_WORK/bin" kubectl-cnpg
  kubectl cnpg version
}

# /tmp is a tmpfs because containerd tests idmapped mounts under /tmp at
# start, and they fail on docker's overlayfs. The HelmChartConfig turns k3s's
# Traefik into a DaemonSet. bench/node-init.sh runs k3s and starts it again
# when it exits, so pods outlive k3s as under systemd.
start_node() {
  local i=$1
  local name=${NODES[$i]} ip=${NODE_IPS[$i]}
  local join=(--cluster-init)
  if ((i > 0)); then
    join=(--server "https://${NODE_IPS[0]}:6443")
  fi
  docker run -d --name "$name" --restart unless-stopped \
    --hostname "$name" --network "$NETWORK" --ip "$ip" \
    --privileged --tmpfs /run --tmpfs /var/run --tmpfs /tmp \
    --ulimit nproc=65535 --ulimit nofile=65535:65535 \
    -e K3S_TOKEN="$K3S_TOKEN" \
    -v "$name:/var/lib/rancher/k3s" \
    -v "$SAMPLES/k3s/manifests/traefik-config.yaml:/var/lib/rancher/k3s/server/manifests/traefik-config.yaml:ro" \
    -v "$REPO/bench/node-init.sh:/node-init.sh:ro" --entrypoint /bin/sh \
    "$K3S_IMAGE" /node-init.sh "${join[@]}" \
    --node-ip "$ip" --tls-san "$ip" \
    --kube-proxy-arg conntrack-max-per-core=0 >/dev/null
}

node_ready() {
  [[ $(k get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') == True ]]
}

# One kubeconfig per node's API server, and $LIVE_WORK/kubeconfig for the first.
write_kubeconfigs() {
  docker exec "${NODES[0]}" test -s /etc/rancher/k3s/k3s.yaml || return 1
  local i config
  config=$(docker exec "${NODES[0]}" cat /etc/rancher/k3s/k3s.yaml)
  for i in "${!NODES[@]}"; do
    echo "${config//https:\/\/127.0.0.1:6443/https://${NODE_IPS[$i]}:6443}" >"$LIVE_WORK/kubeconfig.${NODES[$i]}"
    chmod 600 "$LIVE_WORK/kubeconfig.${NODES[$i]}"
  done
  cp "$LIVE_WORK/kubeconfig.${NODES[0]}" "$LIVE_WORK/kubeconfig"
}

start_k3s() {
  docker network create --subnet "$SUBNET" "$NETWORK" >/dev/null
  timeout 600 docker pull -q "$K3S_IMAGE" >/dev/null
  start_node 0
  wait_for 120 "the kubeconfig of ${NODES[0]}" write_kubeconfigs
  wait_for 300 "node ${NODES[0]} Ready" node_ready "${NODES[0]}"
  local i
  for i in 1 2; do
    start_node "$i"
    wait_for 300 "node ${NODES[$i]} Ready" node_ready "${NODES[$i]}"
  done
}

create_bucket() {
  curl -fsS --max-time 5 --aws-sigv4 aws:amz:us-east-1:s3 --user "$S3_USER:$S3_PASSWORD" \
    -X PUT "http://$S3_IP:9000/$S3_BUCKET"
}

# The store runs next to the nodes. A Service without selector gives it the
# name s3.s3.svc inside the cluster.
start_s3() {
  docker run -d --name s3 --restart unless-stopped \
    --network "$NETWORK" --ip "$S3_IP" -v s3:/data \
    --entrypoint /usr/local/bin/versitygw "$S3_IMAGE" \
    --access "$S3_USER" --secret "$S3_PASSWORD" --port :9000 posix /data >/dev/null
  wait_for 120 "bucket $S3_BUCKET in the store" create_bucket
  k apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: s3
---
apiVersion: v1
kind: Service
metadata:
  name: s3
  namespace: s3
spec:
  ports:
    - name: s3
      port: 9000
      targetPort: 9000
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: s3
  namespace: s3
  labels:
    kubernetes.io/service-name: s3
addressType: IPv4
ports:
  - name: s3
    port: 9000
    protocol: TCP
endpoints:
  - addresses: ["$S3_IP"]
YAML
}

# CoreDNS and metrics-server come from k3s's own manifests, which set no
# replica count and no affinity, so these changes hold across k3s restarts.
spread_k3s_services() {
  k scale deployment coredns -n kube-system --replicas=3 >/dev/null
  k patch deployment metrics-server -n kube-system --type=merge -p '{
    "spec": {"replicas": 3, "template": {"spec": {"affinity": {"podAntiAffinity": {
      "requiredDuringSchedulingIgnoredDuringExecution": [{
        "topologyKey": "kubernetes.io/hostname",
        "labelSelector": {"matchLabels": {"k8s-app": "metrics-server"}}}]}}}}}}' >/dev/null
}

traefik_daemonset() {
  k get daemonset traefik -n kube-system >/dev/null
}

helm_install() {
  timeout 900 helm upgrade --install --wait --timeout 10m "$@" >/dev/null
}

# A self-signed CA behind the Issuer example-ca, the issuer of
# samples/charts/cnpg-cluster/values.yaml. Its certificate is also the client CA.
apply_issuer() {
  k apply -f - >/dev/null <<YAML
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned
  namespace: $NS
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example-ca
  namespace: $NS
spec:
  isCA: true
  commonName: example-ca
  secretName: example-ca
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    kind: Issuer
    name: selfsigned
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: example-ca
  namespace: $NS
spec:
  ca:
    secretName: example-ca
YAML
}

issuer_ready() {
  k wait --for=condition=Ready issuer/example-ca -n "$NS" --timeout=10s
}

apply_chart_inputs() {
  local ca
  ca=$(k get secret example-ca -n "$NS" -o jsonpath='{.data.ca\.crt}' | base64 -d)
  k create secret generic client-ca -n "$NS" --from-literal=ca.crt="$ca" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  k create secret generic backup-creds -n "$NS" \
    --from-literal=ACCESS_KEY_ID="$S3_USER" --from-literal=ACCESS_SECRET_KEY="$S3_PASSWORD" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
}

install_chart() {
  timeout 300 helm upgrade --install pg "$SAMPLES/charts/cnpg-cluster" --namespace "$NS" \
    -f "$SAMPLES/desired.yaml" -f "$LIVE_DIR/values.yaml" >/dev/null
}

# The certificate of orders-app.test, which logs in as orders.
write_client_certificate() {
  k apply -f - >/dev/null <<YAML
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: live-client
  namespace: $NS
spec:
  secretName: live-client
  commonName: orders-app.test
  usages: [client auth]
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    kind: Issuer
    name: example-ca
YAML
  timeout 130 kubectl wait --for=condition=Ready certificate/live-client -n "$NS" --timeout=120s >/dev/null ||
    fail "certificate live-client not Ready after 120s"
  mkdir -p "$CERTS"
  local key
  for key in ca.crt tls.crt tls.key; do
    k get secret live-client -n "$NS" -o jsonpath="{.data.${key//./\\.}}" | base64 -d >"$CERTS/$key"
  done
  chmod 600 "$CERTS/tls.key"
}

# Namespace, label selector and name of every service that runs one pod per
# node.
PER_NODE=(
  "kube-system k8s-app=kube-dns CoreDNS"
  "kube-system app.kubernetes.io/name=traefik Traefik"
  "kube-system k8s-app=metrics-server metrics-server"
  "cert-manager app.kubernetes.io/component=controller cert-manager"
  "cert-manager app.kubernetes.io/component=webhook cert-manager-webhook"
  "cert-manager app.kubernetes.io/component=cainjector cert-manager-cainjector"
  "cnpg-system app.kubernetes.io/name=cloudnative-pg operator"
  "cnpg-system app.kubernetes.io/name=plugin-barman-cloud barman-cloud-plugin"
)

# Each of PER_NODE has three ready pods on three different nodes.
check_placement() {
  local entry ns selector name pods nodes
  for entry in "${PER_NODE[@]}"; do
    read -r ns selector name <<<"$entry"
    pods=$(k get pods -n "$ns" -l "$selector" --no-headers \
      -o custom-columns=NODE:.spec.nodeName,READY:.status.containerStatuses[*].ready)
    nodes=$(awk '$2 == "true" {print $1}' <<<"$pods" | sort -u | paste -sd ' ')
    [[ $(wc -w <<<"$nodes") == 3 && $(wc -l <<<"$pods") == 3 ]] ||
      fail "$name should run one ready pod on each of the three nodes, has: $(paste -sd ';' <<<"$pods")"
    echo "$name: one pod on each of $nodes"
  done
  [[ $(k get pods -n kube-system -l app=local-path-provisioner --no-headers | wc -l) == 1 ]] ||
    fail "local-path-provisioner should run one pod"
}

main() {
  mkdir -p "$LIVE_WORK"
  log "building the client, installing kubectl cnpg $CNPG_PLUGIN_VERSION"
  install_tools
  log "starting k3s"
  start_k3s
  log "starting the object store"
  start_s3
  log "one CoreDNS, Traefik and metrics-server pod per node"
  wait_for 300 "CoreDNS and metrics-server to take the change" spread_k3s_services
  wait_for 300 "the Traefik DaemonSet" traefik_daemonset
  local d
  for d in deployment/coredns deployment/metrics-server daemonset/traefik; do
    timeout 330 kubectl rollout status "$d" -n kube-system --timeout=300s >/dev/null ||
      fail "$d not rolled out after 300s"
  done
  log "installing cert-manager"
  helm dependency build --skip-refresh "$SAMPLES/charts/cnpg-cert-manager"
  wait_for 900 "cert-manager installed" helm_install cert-manager "$SAMPLES/charts/cnpg-cert-manager" \
    --namespace cert-manager --create-namespace
  k create namespace cnpg-system >/dev/null
  k create namespace "$NS" >/dev/null
  wait_for 300 "the Issuer applied" apply_issuer
  wait_for 120 "Issuer example-ca Ready" issuer_ready
  log "installing the CNPG operator and the barman-cloud plugin"
  helm dependency build --skip-refresh "$SAMPLES/charts/cnpg-cloudnative-pg"
  wait_for 900 "the CNPG operator installed" helm_install cnpg "$SAMPLES/charts/cnpg-cloudnative-pg" \
    --namespace cnpg-system
  helm dependency build --skip-refresh "$SAMPLES/charts/cnpg-plugin-barman-cloud"
  wait_for 900 "the barman-cloud plugin installed" helm_install barman-cloud "$SAMPLES/charts/cnpg-plugin-barman-cloud" \
    --namespace cnpg-system
  log "installing samples/charts/cnpg-cluster as release pg in $NS"
  apply_chart_inputs
  wait_for 300 "the samples chart installed" install_chart
  timeout 930 kubectl wait --for=condition=Ready "cluster/$CLUSTER" -n "$NS" --timeout=900s >/dev/null ||
    fail "cluster $CLUSTER not Ready after 900s"
  wait_for 600 "three ready instances, two streaming replicas" settled
  write_client_certificate
  check_placement
  # The scenario's monitoring waits for it to complete.
  k cnpg backup "$CLUSTER" -n "$NS" --backup-name "$FIRST_BACKUP" \
    --method plugin --plugin-name barman-cloud.cloudnative-pg.io >/dev/null
  log "backup $FIRST_BACKUP started"
  k get pods -n "$NS" -l "cnpg.io/cluster=$CLUSTER,cnpg.io/podRole=instance" \
    -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,IMAGE:.spec.containers[?(@.name=="postgres")].image'
  log "ready"
}

main "$@"
