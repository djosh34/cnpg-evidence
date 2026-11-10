Every place where `samples/desired.yaml`, `samples/` and the steps of [samples.md](samples.md) differ from the starting point each upstream project documents, and why. The comparison is with CloudNativePG 1.30.1 (operator chart `cloudnative-pg` 0.29.1), the barman-cloud plugin v0.15.1 (chart `plugin-barman-cloud` 0.8.1), cert-manager v1.21.3, and k3s v1.33.13+k3s2, the version the test cluster runs. "Default" means the chart's `helm show values`, the example manifests in each project's docs, and what CNPG or k3s does when a field is not set.

The last two categories list what only the test cluster in `live/` sets, and the settings that stay at their default although there was a reason to change them.

# k3s

## CoreDNS runs three pods

k3s's CoreDNS manifest sets no replica count, so it runs one pod. The sample scales it to three, one per node. k3s's manifest already spreads CoreDNS pods by host name, so three replicas land on three nodes.

```text
| CoreDNS | `kubectl scale deployment coredns -n kube-system --replicas=3`. k3s's manifest spreads its pods by host name and sets no replica count, so the count holds across k3s restarts as long as a k3s version does not add one |
```

[samples.md](samples.md#one-copy-of-every-service-per-node), [live/up.sh](../live/up.sh)

With one CoreDNS pod, a lost node can take all name lookups in the cluster with it until Kubernetes starts the pod elsewhere, about 5 minutes later. A failover depends on names: a promotion asks the object store, by its host name, for the timeline history and the last WAL file. With the only CoreDNS pod on the lost primary node, that lookup fails and the promotion waits for DNS. With a pod on every node, the other two nodes keep answering. One gap stays: until Kubernetes marks the lost node unreachable, about 50 s, its CoreDNS pod stays in the DNS Service, so about one in three lookups in the cluster times out in that time. Failover waits for the same mark, so this does not delay it.

## Traefik runs as a DaemonSet

k3s installs Traefik from its own HelmChart as a Deployment with one replica, the Traefik chart's default. The sample adds a `HelmChartConfig` that k3s merges into that HelmChart, and Traefik runs as a DaemonSet, one pod on every node.

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    deployment:
      kind: DaemonSet
```

[../samples/k3s/manifests/traefik-config.yaml](../samples/k3s/manifests/traefik-config.yaml)

Every service the cluster relies on runs one pod per node, so a lost node takes no service with it. Traefik serves every Ingress in the cluster. With its one pod on a lost node, every Ingress stops answering until Kubernetes starts the pod on another node, about 5 minutes after the loss. A DaemonSet has a pod on every node and needs no rescheduling.

The file goes into `/var/lib/rancher/k3s/server/manifests/` on every server, so a k3s restart or a new server keeps the setting. Editing k3s's own Traefik manifest would not last: k3s rewrites it on start.

## metrics-server runs three pods, one per node

k3s's metrics-server manifest sets neither replicas nor affinity, so it runs one pod. The sample patches it to three replicas with required pod anti-affinity by host name.

```bash
kubectl patch deployment metrics-server -n kube-system --type=merge -p '{
  "spec": {"replicas": 3, "template": {"spec": {"affinity": {"podAntiAffinity": {
    "requiredDuringSchedulingIgnoredDuringExecution": [{
      "topologyKey": "kubernetes.io/hostname",
      "labelSelector": {"matchLabels": {"k8s-app": "metrics-server"}}}]}}}}}}'
```

[samples.md](samples.md#one-copy-of-every-service-per-node), [live/up.sh](../live/up.sh)

metrics-server serves the resource metrics API through the API server. While that API has no ready pod, it shows as unavailable in API discovery: tools that list every API, such as `kubectl` and Helm, report discovery errors, and the namespace controller cannot finish deleting a namespace. With one pod on a lost node, that lasts until Kubernetes moves the pod, about 5 minutes. With a pod on each node, the other two keep serving. The anti-affinity keeps two replicas from landing on one node. k3s's manifest sets neither field, so the patch holds across k3s restarts.

## Secrets encryption is on

k3s stores Secrets unencrypted in etcd and in its etcd snapshots by default. The sample turns on k3s secrets encryption: `--secrets-encryption` on new servers, or the `k3s secrets-encrypt` steps on a running cluster. `host-check.sh` fails a server where `k3s secrets-encrypt status` does not say `Encryption Status: Enabled`.

```text
By default k3s stores Secrets unencrypted in etcd and in its etcd snapshots. Turn on k3s `secrets-encryption`: `--secrets-encryption` on new servers, or the `k3s secrets-encrypt` steps on a running cluster ([k3s docs](https://docs.k3s.io/security/secrets-encryption)). Snapshots taken before stay unencrypted.
```

[samples.md](samples.md#secrets-encryption), [host-check.md](host-check.md)

The Secrets in the cluster's namespace hold the replication certificate's key, the object store credentials and the server certificate's key. Without encryption they sit in plain text in the datastore on every server's disk and in every etcd snapshot, which k3s takes every 12 hours by default and keeps on the server. A copy of a server's disk or of a snapshot then holds them readable, outside the API server's access control. With encryption on, the datastore and new snapshots hold only ciphertext; the key stays in the server's own directory, which `host-check.sh` checks is mode 0700 and owned by root.

## The API server writes an audit log

The k3s API server writes no audit log by default. The sample gives every server a short audit policy and a log path.

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages: [RequestReceived]
rules:
  - level: Metadata
    namespaces: [databases]
    resources:
      - group: ""
        resources: [pods/exec, pods/attach, secrets]
  - level: None
```

```text
Give it to every server with `--kube-apiserver-arg=audit-policy-file=<path>` and `--kube-apiserver-arg=audit-log-path=<path>`, and keep the log off the node.
```

[samples.md](samples.md#audit-log)

A `kubectl exec` into an instance pod gives a shell next to PostgreSQL's data, and reading a Secret in the cluster's namespace gives its keys. Without an audit log, neither leaves a record of who did it. The policy records, at the `Metadata` level, who opened a shell in, attached to, or read a Secret in the cluster's namespace, without the Secret's content. Everything else is `None`, so the log stays small. A log kept only on the node can be changed by whoever has root on it, so it is shipped off the node.

## SELinux is on in k3s and containerd

A plain k3s install runs containerd without SELinux support. The samples assume hosts with SELinux enforcing and k3s started with its SELinux option, so that containerd's generated config has `enable_selinux = true`. `host-check.sh` fails a node where either is missing.

```text
    ["selinux", "enforcing, enable_selinux true"],
```

[../scripts/desired/host-check.jq](../scripts/desired/host-check.jq), [host-check.md](host-check.md#checks)

`host-check.sh` shows the host side of rule 5, that a host user with the postgres uid cannot reach an instance's socket or data. With SELinux enforcing and containerd's SELinux support on, every container runs under its own SELinux label, so the host's policy confines container processes in addition to their uids. The check reads both the kernel's mode and containerd's setting, because k3s's flag alone does not show what is in effect.

# cert-manager

## The chart installs the CRDs

The cert-manager chart leaves its CRDs out by default (`crds.enabled: false`). The sample's values turn them on, as cert-manager's install docs do with `--set crds.enabled=true`.

```yaml
crds:
  enabled: true
```

[../samples/charts/cnpg-cert-manager/values.yaml](../samples/charts/cnpg-cert-manager/values.yaml)

The barman-cloud plugin chart creates an `Issuer` and two `Certificate`s, and the sample's chart two more `Certificate`s; none of them can be created before the CRDs exist. With the CRDs in the release, one `helm upgrade --install` gives a working cert-manager, and a chart upgrade brings the CRDs of its version. The chart keeps the CRDs when the release is uninstalled (`crds.keep: true`, the default), so an uninstall does not delete every `Certificate` and `Issuer` with them.

## Three pods each of the controller, the webhook and the CA injector

The chart runs one pod each of the controller, the webhook and the CA injector by default. The sample runs three of each.

```yaml
replicaCount: 3
```

```yaml
webhook:
  replicaCount: 3
```

```yaml
cainjector:
  replicaCount: 3
```

[../samples/charts/cnpg-cert-manager/values.yaml](../samples/charts/cnpg-cert-manager/values.yaml)

Every service the cluster relies on runs one pod per node. With one pod on a lost node:

- The controller does not issue or renew certificates, and its metrics on port 9402, which hold `certmanager_certificate_expiration_timestamp_seconds` for `CNPGCertificateExpiring`, are gone.
- The webhook does not answer, and the API server rejects every create or change of a cert-manager object, since the webhook validates them.
- The CA injector does not update the CA bundles of webhook configurations.

Each lasts until Kubernetes starts the pod on another node, about 5 minutes after the loss. The controller and the CA injector elect a leader, so one pod works and the others take over its lease when its node is lost. Every webhook pod serves.

## Required pod anti-affinity for cert-manager's pods

The chart sets no affinity. The sample requires each of the three components to have its pods on different nodes, by host name.

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            app.kubernetes.io/instance: cert-manager
            app.kubernetes.io/component: controller
```

[../samples/charts/cnpg-cert-manager/values.yaml](../samples/charts/cnpg-cert-manager/values.yaml)

Three replicas help only if they are on three nodes. Without anti-affinity the scheduler may place two or three of them on one node, and that node's loss takes them all. `webhook.affinity` and `cainjector.affinity` do the same with their own `app.kubernetes.io/component`.

## cert-manager updates one pod at a time, without an extra pod

The chart sets no update strategy, so Kubernetes uses its default for a Deployment: `maxSurge: 25%` and `maxUnavailable: 25%`. The sample sets `maxSurge: 0` and `maxUnavailable: 1` for all three components.

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 0
    maxUnavailable: 1
```

[../samples/charts/cnpg-cert-manager/values.yaml](../samples/charts/cnpg-cert-manager/values.yaml)

With three replicas, Kubernetes rounds 25 % surge up to one extra pod and 25 % unavailable down to none. The required anti-affinity leaves the extra pod no node to go to, so it stays Pending, no old pod may stop, and the update never ends. With `maxSurge: 0` and `maxUnavailable: 1`, an update stops one old pod, starts its replacement on the freed node, and moves on.

## The issuer of the cluster's certificates is chosen in the chart's values

cert-manager's docs and CNPG's cert-manager example use a self-signed `Issuer`. The sample's chart names an issuer of its own in `values.yaml`, by kind and name, and does not create it: the installer creates it, and its CA must also be in the client CA Secret.

```yaml
issuer:
  kind: Issuer
  name: example-ca
```

[../samples/charts/cnpg-cluster/values.yaml](../samples/charts/cnpg-cluster/values.yaml)

A self-signed issuer gives every certificate its own unrelated signer, so clients cannot check the server against one CA, and CNPG cannot check client certificates against one CA either. The chart instead takes every certificate from one CA issuer whose CA is listed in `caSecret`. The Secret is then the one place that says which CAs the cluster trusts: for client certificates, for the replication certificate and, through the same Secret as the server CA, for the server. The issuer is an input because it is outside the chart's control: it holds the CA key, which the chart never sees. The chart works with an `Issuer` in the cluster's namespace or a `ClusterIssuer`.

## A server certificate from cert-manager with the names in samples/desired.yaml

CNPG creates its own server certificate by default, signed by a CA it generates. CNPG's cert-manager example creates a `Certificate` with every Service name of the cluster in `dnsNames` and no common name. The sample's chart creates `<cluster>-server` with the replication CN as common name, only the `dnsNames` of `samples/desired.yaml`, `server auth` only, and the issuer from `values.yaml`.

```yaml
spec:
  secretName: {{ $c.name }}-server
  commonName: {{ $r.commonName }}
  dnsNames: {{ toJson $r.dnsNames }}
  usages: [server auth]
  issuerRef:
    kind: {{ .Values.issuer.kind }}
    name: {{ .Values.issuer.name }}
```

```yaml
replication:
  commonName: node-1.example.test
  dnsNames: [pg-rw, pg-rw.databases.svc]
```

[../samples/charts/cnpg-cluster/templates/certificates.yaml](../samples/charts/cnpg-cluster/templates/certificates.yaml), [../samples/desired.yaml](../samples/desired.yaml)

The server certificate serves 5432 to clients and replicas, and 9187 to the metrics scrapers (see [Metrics over TLS](#metrics-over-tls)). A client that checks the name, with `verify-full` or a scraper's `server_name`, uses one of the names in `dnsNames`: `pg-rw` with the sample's own names, a node name with a company CA that issues only the node names, as in the bench. Listing only those names keeps one list in `samples/desired.yaml` for both certificates. `server auth` is the only use the certificate has. Both certificates carry the same CN and names, so one CN and one name list in `samples/desired.yaml` describe both.

## A replication certificate from cert-manager with a node's host name as CN

CNPG creates the replication client certificate itself by default, with the CN `streaming_replica`, signed by its own CA. CNPG's cert-manager example also uses the CN `streaming_replica`. The sample's chart creates `<cluster>-replication` from the cert-manager issuer, with the CN and `dnsNames` from `samples/desired.yaml`: the host name of one node.

```yaml
spec:
  secretName: {{ $c.name }}-replication
  commonName: {{ $r.commonName }}
  dnsNames: {{ toJson $r.dnsNames }}
  usages: [client auth]  # CNPG requires clientAuth on this certificate
```

[../samples/charts/cnpg-cluster/templates/certificates.yaml](../samples/charts/cnpg-cluster/templates/certificates.yaml)

With every certificate from one issuer, CNPG holds no CA key of its own: CNPG's own CA would keep its key in a `<cluster>-ca` Secret next to the cluster, and the CA's certificates would be one more set of CAs for clients to trust. The replication certificate is a client certificate like any other: its CN is the host name of one node, in a certificate that the issuer's CA signs. CNPG mounts this one certificate into every instance. Since CNPG maps only the CN `streaming_replica` to the replication role, the chart adds one pg_ident line for this CN (see [pg_ident](#pg_ident-maps-each-client-cn-to-one-role)). CNPG checks that the certificate allows `client auth`.

## The certificate Secrets carry no reload label

CNPG's cert-manager examples create each certificate's Secret ahead of cert-manager, with the label `cnpg.io/reload`. The sample's chart creates only the `Certificate` objects, with no `secretTemplate`, so cert-manager creates their Secrets without that label.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ $c.name }}-server
  namespace: {{ $c.namespace }}
spec:
  secretName: {{ $c.name }}-server
```

[../samples/charts/cnpg-cluster/templates/certificates.yaml](../samples/charts/cnpg-cluster/templates/certificates.yaml)

cert-manager alone creates and renews each Secret, and the chart owns no Secret that cert-manager writes into. The cost is in renewal. CNPG 1.30.1 reacts to a change of a Secret it did not create only when the Secret has the `cnpg.io/reload` label. Without it, a renewed certificate reaches PostgreSQL only at the operator's next reconcile of the cluster, which the renewal itself does not start; any later change of the `Cluster` or its pods does. `CNPGCertificateExpiring` reads the expiry cert-manager reports for the Secret, not the certificate PostgreSQL serves, so it does not see a renewal that PostgreSQL has not loaded yet.

# The CNPG operator

## The operator's upstream RBAC is off; the values chart supplies it

The operator chart creates a ClusterRole and a ClusterRoleBinding by default, which give the operator Secrets, ConfigMaps, `pods/exec` and the rest in every namespace, plus `view` and `edit` ClusterRoles for the CNPG resources. The sample turns the upstream chart's RBAC off and renders `samples/charts/cnpg-cloudnative-pg/templates/rbac.yaml`: a small ClusterRole for the cluster-scoped objects, and the chart's namespaced rules in a ClusterRole that RoleBindings grant only in `cnpg-system` and `databases`.

```yaml
rbac:
  create: false  # the chart would grant secrets and pods/exec in every namespace
```

```yaml
# Cluster-scoped objects only: nodes, webhook configurations, cluster image catalogs.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cnpg-operator-cluster
rules:
  - apiGroups: [""]
    resources: [nodes]
    verbs: [get, list, watch]
  - apiGroups: [admissionregistration.k8s.io]
    resources: [mutatingwebhookconfigurations, validatingwebhookconfigurations]
    verbs: [get, patch]
  - apiGroups: [postgresql.cnpg.io]
    resources: [clusterimagecatalogs]
    verbs: [get, list, watch]
```

```yaml
# The database namespace. Add one of these per extra entry in WATCH_NAMESPACE.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cnpg-operator
  namespace: databases
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cnpg-operator-namespaced}
```

[../samples/charts/cnpg-cloudnative-pg/values.yaml](../samples/charts/cnpg-cloudnative-pg/values.yaml), [../samples/charts/cnpg-cloudnative-pg/templates/rbac.yaml](../samples/charts/cnpg-cloudnative-pg/templates/rbac.yaml)

Rule 6: the operator cannot read Secrets outside its own and the cluster's namespaces. The chart's default binding lets it read every Secret in the cluster and exec into every pod. The rules in the file are the chart's 0.29.1 rules, unchanged; only where they apply changes. The `nodes`, webhook configuration and cluster image catalog rules stay cluster-wide because those objects have no namespace. A second database namespace needs one more RoleBinding, and a chart upgrade needs its RBAC compared with the files ([RBAC on chart upgrades](samples.md#rbac-on-chart-upgrades)), since a rule the files lack shows only as `forbidden` in the operator's log.

## The operator watches only cnpg-system and databases

By default the operator watches every namespace. The sample sets `WATCH_NAMESPACE=cnpg-system,databases` through `additionalEnv`.

```yaml
additionalEnv:
  # The operator watches only these namespaces.
  - name: WATCH_NAMESPACE
    value: cnpg-system,databases
```

[../samples/charts/cnpg-cloudnative-pg/values.yaml](../samples/charts/cnpg-cloudnative-pg/values.yaml)

The RBAC files grant the namespaced rules only in these two namespaces. An operator that watched every namespace would fail to list Secrets, pods and its own resources in the others and log `forbidden` errors without end. With `WATCH_NAMESPACE` it only starts caches where it has rights. A new database namespace goes into this list and gets its RoleBindings; changing the list restarts the operator.

## Three operator pods

The chart runs one operator pod by default. The sample runs three.

```yaml
replicaCount: 3
```

[../samples/charts/cnpg-cloudnative-pg/values.yaml](../samples/charts/cnpg-cloudnative-pg/values.yaml)

The operator promotes a replica when the primary is lost. With its only pod on the lost node, no failover happens until Kubernetes starts the pod on another node, about 5 minutes after the loss. With three pods, one per node, the pods elect a leader; when the leader's node is lost, another pod takes over the lease within about 20 s, and failover goes on.

## Required pod anti-affinity for the operator

The chart sets no affinity. The sample requires the operator's pods to be on different nodes, by host name.

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: cloudnative-pg
```

[../samples/charts/cnpg-cloudnative-pg/values.yaml](../samples/charts/cnpg-cloudnative-pg/values.yaml)

Three replicas help only if they are on three nodes. Without anti-affinity, two operator pods can share a node, and its loss takes the leader and the standby with it.

## The operator updates one pod at a time, without an extra pod

The chart sets no update strategy, so Kubernetes uses `maxSurge: 25%` and `maxUnavailable: 25%`. The sample sets `maxSurge: 0` and `maxUnavailable: 1`.

```yaml
# With a pod on every node, an extra pod during an update has nowhere to go.
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 0
    maxUnavailable: 1
```

[../samples/charts/cnpg-cloudnative-pg/values.yaml](../samples/charts/cnpg-cloudnative-pg/values.yaml)

With three replicas and the default, Kubernetes starts one extra pod and stops none first. The required anti-affinity leaves that pod no node, so it stays Pending and the update never ends. With `maxSurge: 0` an update replaces one pod at a time on its own node.

# The barman-cloud plugin

## The chart's RBAC is off; Secrets are cut to read

The plugin chart creates one ClusterRole and binds it cluster-wide by default. It allows `create`, `delete`, `get`, `list` and `watch` on Secrets in every namespace, along with object stores, backups, roles and role bindings. The sample turns the upstream chart's RBAC off and renders `samples/charts/cnpg-plugin-barman-cloud/templates/rbac.yaml`: `list` and `watch` cluster-wide on object stores, roles and role bindings, and the chart's other rules bound only in `databases`, with Secrets cut to `get`, `list` and `watch`.

```yaml
rbac:
  create: false  # the chart would grant secret create, delete and read in every namespace
```

```yaml
# The plugin's caches watch these at cluster scope, so list and watch are cluster-wide.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: barman-cloud-cluster
rules:
  - apiGroups: [barmancloud.cnpg.io]
    resources: [objectstores]
    verbs: [list, watch]
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [roles, rolebindings]
    verbs: [list, watch]
```

```yaml
  # Read only. The plugin grants each instance read on its object store Secret,
  # and Kubernetes lets it grant only what it holds itself.
  - apiGroups: [""]
    resources: [secrets]
    verbs: [get, list, watch]
```

[../samples/charts/cnpg-plugin-barman-cloud/values.yaml](../samples/charts/cnpg-plugin-barman-cloud/values.yaml), [../samples/charts/cnpg-plugin-barman-cloud/templates/rbac.yaml](../samples/charts/cnpg-plugin-barman-cloud/templates/rbac.yaml)

Rule 6: the plugin cannot read Secrets outside the operator's and the cluster's namespaces. The chart's default would let it read, create and delete every Secret in the cluster. The plugin's caches watch object stores, roles and role bindings at cluster scope, so those three keep cluster-wide `list` and `watch`, which give no Secret. The plugin creates a Role for each instance that lets it read its object store Secret, and Kubernetes lets a subject grant only rights it holds itself, so the plugin needs `get` on Secrets in `databases` and no more. The chart still renders its leader-election Role in `cnpg-system`, with rights only for leader election there.

## Three plugin pods

The chart runs one plugin pod by default. The sample runs three.

```yaml
replicaCount: 3
```

[../samples/charts/cnpg-plugin-barman-cloud/values.yaml](../samples/charts/cnpg-plugin-barman-cloud/values.yaml)

CNPG reconciles a cluster, failover included, only while the barman-cloud plugin answers: a plugin call that fails ends the reconcile. With the only plugin pod on the lost primary node, the cluster has no primary until Kubernetes starts the pod on another node, about 5 minutes after the loss, and CNPG's retries back off further. With three pods, one per node, the pods elect a leader, and a lost leader's lease passes to another pod within about 20 s; a primary node loss then fails over in about a minute.

## Required pod anti-affinity for the plugin

The chart sets no affinity. The sample requires the plugin's pods to be on different nodes, by host name.

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: plugin-barman-cloud
```

[../samples/charts/cnpg-plugin-barman-cloud/values.yaml](../samples/charts/cnpg-plugin-barman-cloud/values.yaml)

Without it two plugin pods can share a node, and its loss takes both, with the delay above.

# The ObjectStore

## A 5 s read timeout on every WAL archive and restore call

The plugin's ObjectStore example passes no extra arguments to barman-cloud, which then uses a 60 s read timeout. The sample passes `--read-timeout=5` to every `barman-cloud-wal-archive` and `barman-cloud-wal-restore` call.

```yaml
    wal:
      compression: gzip
      archiveAdditionalCommandArgs: ["--read-timeout={{ .Values.objectStore.readTimeout }}"]
      restoreAdditionalCommandArgs: ["--read-timeout={{ .Values.objectStore.readTimeout }}"]
```

```yaml
  readTimeout: 5  # --read-timeout of every WAL archive and restore call
```

[../samples/charts/cnpg-cluster/templates/objectstore.yaml](../samples/charts/cnpg-cluster/templates/objectstore.yaml), [../samples/charts/cnpg-cluster/values.yaml](../samples/charts/cnpg-cluster/values.yaml)

Commits and reads never wait for the store, but a failover, a switchover and a starting replica do: a promotion looks up the timeline history and the last WAL file in the store, a starting replica asks the store first for each WAL file it replays, and the old primary in a switchover tries to archive once more before it stops. With barman-cloud's defaults, a store that accepts connections and never answers holds each call for about 5 minutes: a 60 s read timeout and 5 attempts. With this setting and the one attempt below, such a call ends after about 5 s. Against a working store 1 s away, 5 s never failed; 2 s did, so 5 s is the shortest safe value found.

Measured on a three-node k3s cluster, from the event until the new primary took a write, with a store that accepts connections and never answers: about 120 s for a primary node loss and about 90 s for a switchover. Two cases stay at about 60 s per call, because barman-cloud sets no connect timeout and has no option for one: a 1 MB upload to a store that never answers, and any call to a store that drops connections without an answer. With such a store a primary node loss took about 10 minutes and a switchover about 14.

## One attempt per call to the store

barman-cloud uses the AWS SDK's retries, 5 attempts per call by default; the plugin's examples change nothing. The sample sets `AWS_MAX_ATTEMPTS=1` in the plugin's sidecar in each instance.

```yaml
  # The environment of barman-cloud in each instance's sidecar.
  instanceSidecarConfiguration:
    env:
      - name: AWS_MAX_ATTEMPTS
        value: {{ .Values.objectStore.maxAttempts | quote }}
```

```yaml
  maxAttempts: 1  # AWS_MAX_ATTEMPTS in the plugin's sidecar
```

[../samples/charts/cnpg-cluster/templates/objectstore.yaml](../samples/charts/cnpg-cluster/templates/objectstore.yaml), [../samples/charts/cnpg-cluster/values.yaml](../samples/charts/cnpg-cluster/values.yaml)

Each attempt waits out the read timeout again, so 5 attempts of 5 s would still cost about 25 s per call, and a promotion makes several calls. A failed archive or restore is not lost: PostgreSQL calls the archive command again for a WAL file until it succeeds, and a replica asks for the next WAL file again. So retrying inside one call only makes a broken store slower to give up on. With one attempt, a call ends at its first failure.

The setting also applies to the plugin's own reads of the store. When the primary's plugin sidecar starts, and every `retentionPolicyIntervalSeconds` after that, it lists the store's backups. If the store does not answer every read of that list, Barman can return a list without the backup and still succeed, and the plugin then reports its last backup as 0. More attempts would make that rarer, but every call during a failover would again wait out several read timeouts. The value stays 1, and the backup alert and the dashboard read the newest backup of the last 2 h instead (see [Backup age from the newest backup of the last 2 h](#backup-age-from-the-newest-backup-of-the-last-2-h)).

## The backup bucket: credentials for one bucket, encrypted at rest

The plugin's examples name a bucket and a credentials Secret and say nothing about the bucket itself. The sample gives the credentials in `objectStore.credentialsSecret` access to this one bucket only, and turns on encryption at rest for the bucket.

```text
The bucket holds every database's WAL and base backups. Give the credentials in `objectStore.credentialsSecret` access to this one bucket only, and turn on encryption at rest for the bucket.
```

[samples.md](samples.md#backup-bucket)

The bucket holds a full copy of every database: its base backups and every WAL file since. The credentials sit in a Secret in the cluster's namespace and in every instance's sidecar. Limited to one bucket, they reach no other data in the store. Encryption at rest keeps the copies unreadable on the store's own disks.

# The Cluster

## Red Hat's Hummingbird PostgreSQL image, pinned by digest

CNPG 1.30.1 runs `ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie` when `imageName` is not set. The sample runs Red Hat's Hummingbird image `registry.access.redhat.com/hi/postgresql:18.6`, pinned by its digest.

```yaml
  # Red Hat's Hummingbird PostgreSQL image, pinned by digest.
  imageName: registry.access.redhat.com/hi/postgresql:18.6@sha256:d6cfb70eb81d7843ead5e516b40ceaff10166f9449cb57ac8bbee33688cb26d3
```

[../samples/charts/cnpg-cluster/values.yaml](../samples/charts/cnpg-cluster/values.yaml)

Hummingbird is a minimal image that pulls without a login. It has bash, coreutils and `psql`, and no `openssl`; the scripts in `scripts/` run only `psql` in it, always as `-U postgres`, so they work with this image and with any image that has `psql`. A tag can be pushed again with other content; a digest cannot. With the digest, every instance runs the same image, and a new image reaches the cluster only through a change of the chart's values, which rolls the instances one at a time.

## PostgreSQL runs as uid and gid 999

CNPG runs PostgreSQL as uid and gid 26 by default, the ids of `postgres` in CNPG's own images. The sample sets 999, the ids the Hummingbird image names `postgres`.

```yaml
  postgresUID: 999
  postgresGID: 999
```

```yaml
  postgresUID: {{ $c.postgresUID }}
  postgresGID: {{ $c.postgresGID }}
```

[../samples/charts/cnpg-cluster/values.yaml](../samples/charts/cnpg-cluster/values.yaml), [../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml)

CNPG writes the name of the uid PostgreSQL runs as into pg_ident, in its fixed line `local <user> postgres`. In the Hummingbird image, uid 26 is named `postgres_fedora`, so with CNPG's default the line names `postgres_fedora`, and the compliance metric and `evidence.sh` find wrong pg_ident lines. The ids are set when the cluster is created, since the data directory is owned by them. `host-check.sh` and `prove.sh` take the same ids with `--postgres-uid` and `--postgres-gid`.

## PostgreSQL runs in a pod user namespace

CNPG's instance pods share the host's uids by default. The chart adds `hostUsers: false` to every instance pod through CNPG's `cnpg.io/podPatch` annotation.

```yaml
  annotations:
    # Runs postgres in a pod user namespace: uid {{ $c.postgresUID }} in the pod is another uid on the host.
    cnpg.io/podPatch: '[{"op":"add","path":"/spec/hostUsers","value":false}]'
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml)

Rule 5: a host user with the postgres uid cannot reach the socket or the data of an instance. Without a user namespace, uid 999 in the pod is uid 999 on the host, and a host account with that uid owns PostgreSQL's files and socket. With `hostUsers: false`, uid 999 in the pod maps to another uid on the host, from a range Kubernetes gives the pod, and a host user with uid 999 is nobody inside the pod. The `Cluster` has no field for `hostUsers`, so the chart uses the podPatch annotation. It applies only to new pods, so pods that already run need a rolling restart. The node's kernel needs idmapped mounts on tmpfs.

## The data volume is 50Gi

CNPG's examples use `storage.size: 1Gi`. The sample uses 50Gi.

```yaml
  # The data volume of each instance. pg_wal is on it and keeps up to
  # walKeepSize, plus the data.
  storageSize: 50Gi
```

[../samples/charts/cnpg-cluster/values.yaml](../samples/charts/cnpg-cluster/values.yaml)

Every instance keeps up to `walKeepSize`, 30GB, of WAL in `pg_wal` on its data volume (see [wal_keep_size](#wal_keep_size-is-30gb)). The volume must hold that plus the data; 1Gi would fill with WAL. On `local-path` the size is not enforced, so the volume shares the node's disk, which `CNPGDataDiskFull` watches.

## WAL files of 1 MB

PostgreSQL's WAL files are 16 MB by default, and CNPG passes no `--wal-segsize` to initdb unless `walSegmentSize` is set. The sample sets 1 MB.

```yaml
      walSegmentSize: {{ $c.walSegmentSize }}  # MB; a restore takes the backup's size
```

```yaml
  walSegmentSize: 1
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml), [../samples/charts/cnpg-cluster/values.yaml](../samples/charts/cnpg-cluster/values.yaml)

PostgreSQL switches to a new WAL file at least every 5 minutes (CNPG's `archive_timeout`), and a switched file keeps its full size. A quiet cluster then writes 288 MiB of WAL a day instead of 4.5 GiB, so `wal_keep_size` holds months of a quiet cluster's WAL instead of days, and the store grows more slowly. The costs: each file is one call to the store, so the archive keeps up only while the primary writes less than about 2.5 MB/s, and initdb sets `max_wal_size` to 64 MB, so a primary under load makes a checkpoint every 64 MB of WAL. The size is fixed when a cluster is created; a restore keeps the size of its backup.

## wal_keep_size is 30GB

CNPG sets `wal_keep_size` to 512MB by default. The sample sets 30GB.

```yaml
      wal_keep_size: {{ $c.walKeepSize | quote }}
```

```yaml
  walKeepSize: 30GB
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml), [../samples/charts/cnpg-cluster/values.yaml](../samples/charts/cnpg-cluster/values.yaml)

Without replication slots (below), `wal_keep_size` is what the primary keeps for a replica that was down. A replica whose WAL is still in the primary's `pg_wal` catches up from the primary alone; one that is further behind needs the object store. A quiet cluster writes about 288 MiB of WAL a day, so 30GB is about three months; writes add their own WAL. With the store refusing connections, a replica that was down while 1.2 GB of WAL was written caught up from the primary alone, about 40 s after its node started. With 512MB it would need the store for that. Every instance keeps this much, so the data volume must hold it.

## No replication slots

CNPG creates a replication slot on the primary for each replica by default (`replicationSlots.highAvailability.enabled: true`). The sample turns them off.

```yaml
  # No replication slots: a slot keeps WAL for an instance that is gone until
  # the disk is full. A replica that falls behind reads the WAL its primary
  # no longer keeps from the object store.
  replicationSlots:
    highAvailability:
      enabled: false
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml)

A slot keeps WAL on the primary for its replica until the replica returns, without a limit. An instance that stays away, a lost node that is not replaced for days, fills the primary's disk, and PostgreSQL stops. Capping slots with `max_slot_wal_keep_size` instead invalidates the slot when the cap is reached, and the replica then needs a person. Without slots, the primary keeps `wal_keep_size` of WAL, and an instance that is further behind reads the rest from the object store by itself. PostgreSQL removes a WAL file only after it is archived, so the store and the primary's `pg_wal` always overlap, and the replica can always catch up while nothing deletes WAL from the store.

## One instance per node, required

CNPG's pod anti-affinity between instances is `preferred` by default. The sample makes it `required`.

```yaml
  # One instance per node, so the synchronous copy is on another node.
  affinity:
    podAntiAffinityType: required
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml)

Every commit waits for one other instance to confirm it. With `preferred`, the scheduler may put two instances on one node when another node is missing or full, and a commit's two copies can then be on one node, which a single node loss takes both of. The read LoadBalancer also forwards each node's read port only to the instance on that node, which assumes one instance per node. With `required`, an instance that has no free node stays Pending instead.

## Synchronous replication: any 1, required

CNPG runs without synchronous replication by default. The sample makes every commit wait for one of the other instances.

```yaml
    synchronous:
      method: any
      number: 1  # every commit waits for one other instance
      dataDurability: required  # and stops while no other instance can confirm it
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml)

With asynchronous replication, a commit is acknowledged once the primary has it. When the primary's node is lost, a replica that missed the last commits can be promoted, and those acknowledged commits are gone. With `any 1`, a commit returns only once one of the two replicas has it, so a promotion can pick a replica that holds every acknowledged commit. One copy, not two, keeps writes going when one replica is down. When no other instance can confirm, writes stop instead of going on with one copy. A commit whose wait for the standby was cancelled may still be committed, so a client treats a cancelled COMMIT as unknown.

## synchronous_commit is remote_apply

PostgreSQL's default `synchronous_commit` is `on`: the commit waits until the standby has flushed the WAL, not until it has applied it. The sample sets `remote_apply`.

```yaml
      # A commit returns once one other instance has applied it, so a read
      # there right after sees it.
      synchronous_commit: remote_apply
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml)

Reads also go to replicas, through the read port. With `on`, a client can commit, then read on the replica that confirmed the commit, and not see its own write yet. With `remote_apply`, the commit returns only once that replica has applied it, so a read there right after the commit sees it. The other replica can still be behind; `CNPGReplicaLag` watches it.

## Failover quorum

CNPG promotes the most advanced ready replica by default, without checking that it holds every confirmed commit. The sample turns on `failoverQuorum`.

```yaml
      failoverQuorum: true  # promotes only a replica that holds every confirmed commit
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml)

With `any 1`, either replica may have confirmed a commit. Without the quorum, CNPG could promote a replica that is ready but did not receive the last confirmed commits, and they would be lost. With the quorum, CNPG promotes a replica only when it can tell that the replica holds every confirmed commit. With one confirming copy and two replicas, it needs both replicas ready to decide. A replica that restarts while the primary's node is down is ready again once it has replayed its own WAL, so the quorum then sees both replicas and promotes, some seconds later than otherwise.

## A stopping instance ends open sessions at once

CNPG gives a stopping instance's smart shutdown 180 s by default (`smartShutdownTimeout`), during which open sessions may go on. The sample sets 0.

```yaml
  smartShutdownTimeout: 0
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml)

A smart shutdown waits for every session to close, and a connection pool never closes its sessions by itself. A primary that stops, in a rollout or a switchover, would then hold writes for up to 180 s before the fast shutdown. With 0, it ends open sessions at once. A rollout for a parameter that needs a restart then stops writes for about 6 s, and a switchover for about 11 s, also with a pooled session open. A commit that is still waiting for its standby then ends with the warning that it committed locally but might not have been replicated; it stays committed.

## No app database, app role or app Secret

CNPG's `initdb` creates a database `app`, a role `app` that owns it, and a `<cluster>-app` Secret with its password by default. The sample's chart bootstraps with `database: postgres`, `owner: postgres` and a placeholder Secret `<cluster>-bootstrap`, for `initdb` and for `recovery` alike.

```yaml
      database: postgres  # no app database
      owner: postgres     # no app role
      secret:
        name: {{ $c.name }}-bootstrap  # placeholder, so CNPG creates no <cluster>-app Secret
```

```yaml
type: kubernetes.io/basic-auth
stringData:
  username: postgres
  password: ""
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml), [../samples/charts/cnpg-cluster/templates/bootstrap-secret.yaml](../samples/charts/cnpg-cluster/templates/bootstrap-secret.yaml)

Rule 4: there is no `app` role or database. The `app` role logs in with a password, which rule 2 forbids, and its Secret holds that password in the cluster's namespace. Each application gets its own role and database instead (see [Databases](#one-database-object-per-database)). `initdb` reads the username from the named Secret; the empty password leaves `postgres` with no password, since CNPG writes it onto `postgres` and PostgreSQL stores an empty password as none. A restore gets the same fields, so a restored cluster creates no `app` either.

## The bootstrap creates the metrics exporter role and two grants

CNPG's `initdb` runs no `postInitSQL` by default. The sample's runs three statements.

```yaml
      postInitSQL:
        - CREATE ROLE cnpg_metrics_exporter WITH LOGIN PASSWORD NULL
        - GRANT SELECT ON pg_ident_file_mappings TO cnpg_metrics_exporter
        - GRANT EXECUTE ON FUNCTION pg_ident_file_mappings() TO cnpg_metrics_exporter
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml)

The compliance query reads `pg_ident_file_mappings`, which only superusers may read by default, and runs as `cnpg_metrics_exporter`. The two grants let it read that view and nothing else. CNPG creates `cnpg_metrics_exporter` only after `postInitSQL`, so the chart creates the role first, as CNPG would, with no password; CNPG then keeps it and adds `pg_monitor`. Without the grants the query fails and `CNPGMetricsMissing` fires. `evidence.sh` expects exactly these grants: `postgres` and `cnpg_metrics_exporter`, no other role.

## Certificates from cert-manager and the client CA Secret

CNPG generates its own CA, server certificate and replication certificate by default, and verifies client certificates against its own CA. The sample names all four Secrets: the server and replication certificates from cert-manager, and the hand-made client CA Secret as both the server CA and the client CA.

```yaml
  certificates:
    serverTLSSecret: {{ $c.name }}-server
    serverCASecret: {{ .Values.caSecret }}
    clientCASecret: {{ .Values.caSecret }}  # client certificates are checked against the CAs in this Secret
    replicationTLSSecret: {{ $c.name }}-replication  # the replication certificate from certificates.yaml
```

```yaml
caSecret: client-ca
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml), [../samples/desired.yaml](../samples/desired.yaml)

Rule 1: a client logs in only with a certificate signed by the client CA. With CNPG's own CA, the CA's key sits in a `<cluster>-ca` Secret in the cluster's namespace, and every certificate that key signed is a valid client certificate. With all four Secrets given, CNPG generates no CA and holds no CA key. The client CA Secret holds only `ca.crt`, made by hand from the CAs that may sign client certificates, so the list of trusted CAs is written down in one place and changes only by hand. The issuer's CA is in it too, since it signs the server and replication certificates. Using the same Secret as the server CA lets clients and replicas check the server against the CAs they already trust, and lets `evidence.sh --ca` compare one file.

## pg_hba: one certificate line per database, then reject

CNPG's `pg_hba.conf` ends with `host all all all scram-sha-256`, so any role can log in with a password by default. The sample adds one `hostssl ... cert map=clients` line per database, and a `reject` line for every other TCP connection, before CNPG's final password line.

```yaml
    pg_hba:
      # One line per database: only its own role, only with a certificate.
      {{- range .Values.databases }}
      - hostssl {{ .name }} {{ .role }} all cert map=clients
      {{- end }}
      # Rejects every other TCP connection before CNPG's final password line.
      - host all all all reject
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml)

Rules 1 and 2: a client logs in only with a certificate signed by the client CA, its role reaches exactly one database, and no password login works, with or without TLS. `pg_hba.conf` uses the first line that matches. CNPG's fixed lines come first: `local all all peer` and the certificate lines of `streaming_replica` and the pooler. Then each `hostssl` line lets one role into one database with a certificate. The `reject` line ends every other TCP connection before CNPG's `scram-sha-256` line is reached. `hostssl` with `cert` also needs TLS, and CNPG allows only TLS 1.3 by default.

## pg_ident maps each client CN to one role

CNPG's `pg_ident.conf` has its fixed lines only by default; its replication map accepts the CN `streaming_replica`. The sample adds the replication CN to that map, and a map `clients` with one line for each client CN.

```yaml
    pg_ident:
      # Maps the replication certificate's CN to streaming_replica.
      - cnpg_streaming_replica {{ $replicationCN }} streaming_replica
      # Exact CNs, each to one role.
      {{- range .Values.databases }}
      {{- $role := .role }}
      {{- range .clientCNs }}
      - clients {{ . }} {{ $role }}
      {{- end }}
      {{- end }}
```

```yaml
databases:
  - name: orders
    role: orders
    clientCNs: [orders-app.test]
  - name: billing
    role: billing
    clientCNs: [billing-app.test, billing-report.test]
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml), [../samples/desired.yaml](../samples/desired.yaml)

With `cert` alone, a client logs in only as the role named like its certificate's CN. A map lets the CN differ from the role, and with exact CNs a certificate maps to one role and nothing else: no regular expressions, so no other CN matches by accident. Several CNs may map to one role, as `billing` shows. The replication certificate's CN is a node's host name, not `streaming_replica`, so the chart adds it to CNPG's `cnpg_streaming_replica` map, and only that CN. The compliance query counts any line that differs from these.

## Application roles are managed, LOGIN only, without a password

CNPG manages no roles besides its own by default. The sample declares one role per database with `LOGIN`, every other attribute off, and `disablePassword: true`.

```yaml
      - name: {{ .role }}
        ensure: present
        login: true
        superuser: false
        createdb: false
        createrole: false
        replication: false
        bypassrls: false
        disablePassword: true  # PASSWORD NULL
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml)

Rule 3: no application role can create roles or has any other special attribute. Rule 2: no password login works. `disablePassword` sets the password to NULL, so the role has no password at all, even if a pg_hba line allowed one. The attributes that equal CNPG's defaults are written out, so the template shows every attribute the role has. CNPG does not undo a change made in PostgreSQL itself right away; the compliance query and `evidence.sh` find it.

## One Database object per database

CNPG's default bootstrap makes the one database `app`. The sample creates each database from `samples/desired.yaml` as a CNPG `Database` object, owned by its role.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: {{ $c.name }}-{{ .name }}
  namespace: {{ $c.namespace }}
spec:
  cluster:
    name: {{ $c.name }}
  name: {{ .name }}
  owner: {{ .role }}
  ensure: present
```

[../samples/charts/cnpg-cluster/templates/databases.yaml](../samples/charts/cnpg-cluster/templates/databases.yaml)

Each role reaches exactly one database, its own. A new database is one more entry in `samples/desired.yaml` and a `helm upgrade`, with no SQL by hand.

## The rw LoadBalancer, without NodePorts

CNPG creates only the ClusterIP Services `<cluster>-rw`, `-ro` and `-r` by default. CNPG's docs show an extra LoadBalancer for `rw`. The sample adds that LoadBalancer with `allocateLoadBalancerNodePorts: false`.

```yaml
        # 5432 on every node, to the primary.
        - selectorType: rw
          serviceTemplate:
            metadata:
              name: {{ .Values.rwLoadBalancer.name }}
            spec:
              type: LoadBalancer
              allocateLoadBalancerNodePorts: false
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml)

Clients outside the cluster reach the primary on 5432 of every node: k3s servicelb opens the LoadBalancer's port on every node and forwards it to the primary. A LoadBalancer also gets a NodePort by default, a second, random high port on every node that leads to the same primary. With `allocateLoadBalancerNodePorts: false`, PostgreSQL is reached on the nodes only through the LoadBalancer's own port, and the NetworkPolicy has one port to admit.

## The read LoadBalancer: each node to its own instance

CNPG has no per-node read Service. The sample adds an optional LoadBalancer of `selectorType: r` with `externalTrafficPolicy: Local`, on its own port, also without NodePorts.

```yaml
        - selectorType: r
          serviceTemplate:
            metadata:
              name: {{ required "readLoadBalancer.name is required" .name }}
            spec:
              type: LoadBalancer
              externalTrafficPolicy: Local
              allocateLoadBalancerNodePorts: false
              ports:
                - name: postgres  # with another name CNPG adds 5432 as well
                  protocol: TCP
                  port: {{ required "readLoadBalancer.port is required" .port }}
                  targetPort: 5432
```

```yaml
readLoadBalancer:
  name: pg-read-lb
  port: 5433
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml), [../samples/desired.yaml](../samples/desired.yaml)

While no rw address takes a connection, a client outside the cluster can still read. With traffic policy Local, a node forwards the read port only to the instance on that node, primary or replica, and only while that instance is ready. A node without a ready instance refuses the port, so a client moves on to the next node at once instead of waiting for a dead instance. Connections keep the client's address. When the primary's node is lost, reads keep working on the replicas' nodes without waiting for a failover. The port is named `postgres` because CNPG adds 5432 to the Service when no port has that name. The read LoadBalancer still has a `healthCheckNodePort`, which Kubernetes gives every LoadBalancer with traffic policy Local; it answers over HTTP and does not lead to PostgreSQL. `pgfallback` is the client side: rw first, the read port only while no rw address takes a connection.

## Metrics over TLS

CNPG's metrics exporter answers over plain HTTP on 9187 by default. The sample turns on TLS for it.

```yaml
  monitoring:
    tls:
      enabled: true  # metrics on 9187 over TLS with the server certificate
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml)

Rule 1: the metrics port answers only over TLS. The exporter then uses the server certificate, so scrapers check it with the CA in `caSecret` and one of the `dnsNames` as `server_name`. The metrics include role names, database names and replication state.

## The chart's queries in a Secret listed in customQueriesSecret

CNPG runs only its default queries by default, from the operator's `cnpg-default-monitoring` ConfigMap. The sample adds three queries in a Secret `<cluster>-queries`, labelled `cnpg.io/reload`, and lists it in `monitoring.customQueriesSecret`.

```yaml
    customQueriesSecret:
      - name: {{ $c.name }}-queries
        key: queries
```

```yaml
  labels:
    cnpg.io/reload: ""  # the instances load a changed query without a restart
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml), [../samples/charts/cnpg-cluster/templates/queries.yaml](../samples/charts/cnpg-cluster/templates/queries.yaml)

The three queries:

- `compliance` reports `cnpg_compliance_violations{rule, check}`: per check the number of roles, attributes or pg_ident lines that break it, 0 when it passes. It shows a changed role or mapping within a scrape, between runs of `evidence.sh`.
- `replica` reports `cnpg_replica_lag_seconds`: 0 when the replica has replayed all the WAL its primary last reported, otherwise the age of the last transaction it replayed. CNPG's `cnpg_pg_replication_lag` compares with the received WAL instead, which after a restart of PostgreSQL stays behind until the primary writes again, and so reports minutes on a replica that is caught up; in tests that false lag lasted up to 5 minutes after a primary change.
- `sync_replication` reports `cnpg_sync_replication_waiting`: the sessions waiting right now for a standby to confirm their commit, for `CNPGWritesBlocked`.

A Secret rather than a ConfigMap: with a Secret listed in `customQueriesSecret`, CNPG 1.30.1 does not rewrite the `Cluster` status many times a second while a lost pod is marked for deletion. That loop gives every instance a new, empty set of query results on each change, so every exporter answers without the query metrics until the node returns. The label lets the instances load a changed query without a restart.

## Every scrape runs the queries

CNPG caches query results for 30 s by default (`metricsQueriesTTL`). The sample sets 0s.

```yaml
    # Every scrape runs the queries: with CNPG's 30 s cache a commit that
    # waited a moment for its standby would show as waiting for 30 s.
    metricsQueriesTTL: 0s
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml)

`CNPGWritesBlocked` fires when sessions wait for a standby at every scrape for 10 s. With the 30 s cache, a commit that waited a moment would be reported as waiting for 30 s, and the alert would fire for a wait that was long over. A role change would also show only up to 30 s late. With 0s, each scrape, every 5 s, runs the queries.

## The NetworkPolicy

CNPG creates no NetworkPolicy. The sample's chart renders one ingress policy for every pod of the cluster: 5432 and 8000 from the cluster's own pods, 8000 from the operator, 9187 from the OTel namespace, and 5432 from outside the cluster, from the other nodes and from the rw LoadBalancer's svclb pods.

```yaml
  # Instances and their bootstrap and join Job pods; podRole would miss the Jobs.
  podSelector:
    matchLabels:
      cnpg.io/cluster: {{ $c.name }}
  policyTypes: [Ingress]
```

```yaml
    - from:
        # Any address that is not a pod.
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              {{- range $nodes }}
              - {{ .spec.podCIDR }}
              {{- end }}
```

```yaml
network:
  operatorNamespace: cnpg-system
  otelNamespace: otel
```

[../samples/charts/cnpg-cluster/templates/networkpolicy.yaml](../samples/charts/cnpg-cluster/templates/networkpolicy.yaml), [../samples/desired.yaml](../samples/desired.yaml)

Without a policy, every pod in the cluster can reach 5432, the instance status API on 8000 and the metrics on 9187. With it, other pods in the cluster reach none of them, apart from the operator on 8000 and the OTel collectors on 9187. Clients come from outside the cluster, so 5432 stays open to every address that is not a pod. The policy reads every node's `spec.podCIDR` with `lookup`, so it needs a cluster to render and a `helm upgrade` when a node is added. Under flannel, a connection that entered through another node arrives from that node's `flannel.1` address, the network address of its pod range, so each of those is admitted as a `/32`. Connections through the rw LoadBalancer that enter on another node arrive from its svclb pods. The podSelector is the cluster label rather than `podRole`, so the bootstrap and join Job pods are covered too. k3s enforces it with its network policy controller, which `host-check.sh` checks.

# Monitoring

## Alert rules of the sample instead of CNPG's example rules

CNPG's docs ship an example `PrometheusRule` with seven alerts, each `warning` and each after 1 minute, on every cluster the metrics come from. The sample ships eleven alerts of its own in plain Prometheus rule-file format, mostly `critical`, each limited to the clusters listed in `cnpg_sample:database`.

```yaml
      - record: cnpg_sample:database
        expr: vector(1)
        labels:
          namespace: databases
          cluster: pg
```

[../samples/monitoring/rules.yaml](../samples/monitoring/rules.yaml)

The rules run in a rule evaluator outside the Kubernetes cluster, Prometheus or the Mimir ruler, so they are a rule file rather than a `PrometheusRule` for the Prometheus operator. Each alert is something a person must act on, so most are critical, and a dashboard tile is red only while one fires. The waiting times match how long each state may last on its own: a failover takes about a minute, so `CNPGDatabaseDown` waits 3 minutes. `cnpg_sample:database` names each database once, so an alert about the whole database is one alert per database, and a missing database shows as an alert rather than as no series. The alerts read the chart's queries and the sample's settings: there are no replication slots to watch, and the replica lag and writes-blocked alerts use the chart's own queries.

## Replica lag from the chart's query, 15 s for 2 minutes

CNPG's example `PGReplication` alert fires when `cnpg_pg_replication_lag` is above 300 s for 1 minute. The sample's `CNPGReplicaLag` reads `cnpg_replica_lag_seconds` and fires above 15 s for 2 minutes.

```yaml
      - alert: CNPGReplicaLag
        expr: |
          max by (namespace, cluster, pod) (cnpg_replica_lag_seconds) > 15
          and on (namespace, cluster) cnpg_sample:database
        for: 2m
```

[../samples/monitoring/rules.yaml](../samples/monitoring/rules.yaml)

Every commit waits for one replica only, so the other one can fall behind while writes go on, and it still serves reads on its node's read port. With 300 s, a replica can serve reads five minutes old before anyone hears of it. `cnpg_pg_replication_lag` also reports minutes on a caught-up replica after a restart of PostgreSQL, until the primary writes again; an alert on it fires falsely after a primary change. The chart's query reports 0 when the replica has replayed everything its primary reported. On the test cluster, every replica's `cnpg_replica_lag_seconds` stayed under 1 s for 330 s after a switchover and after a fence, longer than the 5 minutes of false lag CNPG's metric showed.

## A down replica from the primary's pg_stat_replication

CNPG's example `ReplicaFailingReplication` alert compares `in_recovery` with `is_wal_receiver_up` on each replica. The sample's `CNPGReplicaDown` compares the instances seen in the last day with the primary's `pg_stat_replication`, and also fires for an instance whose metrics stopped.

```yaml
      - record: cnpg_sample:replica_streaming
        expr: |
          count by (namespace, cluster, pod) (
            label_replace(
              cnpg_pg_stat_replication_backend_start
                and on (namespace, pod) cnpg_pg_replication_in_recovery == 0,
              "pod", "$1", "application_name", "(.+)"))
```

[../samples/monitoring/rules.yaml](../samples/monitoring/rules.yaml)

A replica on a lost node reports nothing, so an alert on its own metrics never fires for it. The primary knows which replicas stream to it: CNPG names each replica by its pod in `application_name`. Without replication slots, `pg_stat_replication` is the primary's view of its replicas. An instance seen in the last day that is neither the primary nor streaming is down, whether its pod is gone, it does not stream, or its scrape fails.

## Writes blocked, evaluated every 5 s

CNPG's example rules have no alert for commits that wait for a standby. Prometheus evaluates rules every minute by default. The sample's `CNPGWritesBlocked` fires when sessions wait at every scrape for 10 s, in a group evaluated every 5 s, with the exporter scraped every 5 s.

```yaml
  - name: cnpg-sample-writes
    interval: 5s
```

```yaml
        for: 10s
```

[../samples/monitoring/rules.yaml](../samples/monitoring/rules.yaml), [monitoring.md](monitoring.md#scrape-targets-and-labels)

With `dataDurability: required`, every write waits while no standby confirms; reads still work. That is an outage of writes, and it can start without any pod being down, for example when replay stalls on both replicas. A session counts only while its commit waits, so a long statement does not fire it. A wait of 10 s is an outage a person must hear of. Seeing it in time needs an evaluation and a scrape every 5 s; with the default of 1 minute it would show only after a minute or more.

## Data disk alerts at 70 % and 80 %

CNPG's example rules have no disk alert. The sample's `CNPGDataDiskFull` warns at 70 % and is critical at 80 % of the disk each instance keeps its data on, from the kubelet's volume stats.

```yaml
      - alert: CNPGDataDiskFull
        expr: cnpg_sample:data_disk_used_ratio > 0.8
        for: 5m
        labels:
          severity: critical
```

[../samples/monitoring/rules.yaml](../samples/monitoring/rules.yaml)

A full data volume stops PostgreSQL. WAL that is not archived yet is never removed, so a broken store or a primary that writes faster than the archive grows `pg_wal` until the volume is full. For a `local-path` volume the kubelet reports the whole filesystem of the node the volume is on, so that disk is what fills. On k3s the kubelet starts to evict pods from a node at about 85 %, since by default it keeps 10 % of the node's filesystem and 15 % of the image filesystem free, and both are that same disk. 80 % comes before eviction.

## Certificate expiry of the chart's two certificates

CNPG's example rules have no certificate alert. The sample's `CNPGCertificateExpiring` warns 14 days and is critical 3 days before the chart's server or replication certificate expires, as cert-manager reports it.

```yaml
      - alert: CNPGCertificateExpiring
        expr: cnpg_sample:certificate_expiration_timestamp_seconds - time() < 3 * 86400
```

[../samples/monitoring/rules.yaml](../samples/monitoring/rules.yaml)

The certificates are not CNPG's own, so CNPG does not renew them; cert-manager does. A renewal that fails leaves an expiring certificate. An expired server certificate stops every client that checks it, and an expired replication certificate stops the replicas from logging in, after which writes stop too. cert-manager's controller reports the expiry on port 9402.

## Backup age from the newest backup of the last 2 h

CNPG's example rules alert only on a failed WAL archive (`LastFailedArchiveTime`), and have no alert for the age of the last backup. The sample's `CNPGBackupFailing` also fires when the last backup is older than 26 h, when there is none, or when the last backup failed. It takes the newest backup the barman-cloud plugin reported in the last 2 h. The dashboard's **Last backup** panel reads the same value.

```yaml
            time() - max by (namespace, cluster) (max_over_time(barman_cloud_cloudnative_pg_io_last_available_backup_timestamp[2h])) > 26 * 3600
```

```python
BACKUP_AGE = f"time() - max(max_over_time(barman_cloud_cloudnative_pg_io_last_available_backup_timestamp{{{S}}}[2h]) > 0)"
```

[../samples/monitoring/rules.yaml](../samples/monitoring/rules.yaml), [../samples/monitoring/dashboard.py](../samples/monitoring/dashboard.py)

A cluster without a recent backup cannot be restored to a recent state, and a failed or missing base backup does not show in the WAL archive's metrics. The 26 h fits a daily backup, a daily schedule plus 2 h; it changes with the schedule.

The barman-cloud plugin can report its last backup as 0 for a while when the backup is still in the store. The primary's plugin sidecar lists the store's backups when it starts and every `retentionPolicyIntervalSeconds` (30 min by default). If the store does not answer every read of that list, Barman can return a list without the backup and still succeed. The plugin then deletes the `Backup` object of each backup missing from the list, and reports 0. With the plain metric, the alert's condition then holds and the panel has no data. In live runs this happened in 4 of 20 runs of `one-node-left` with the writer, when the primary came back after its node and another node were lost. The backup in the store is not touched, but its `Backup` object stays deleted. With the newest value of the last 2 h, such a 0 is ignored for 2 h. A 0 that lasts longer counts as no backup, and the alert fires 10 minutes later.

## Too many connections, at 90 % for 5 minutes

CNPG's example rules have no alert on the number of connections. The sample's `CNPGConnectionsHigh` fires when an instance has more than 90 % of `max_connections` open for 5 minutes.

```yaml
      - alert: CNPGConnectionsHigh
        expr: |
          sum by (namespace, cluster, pod) (cnpg_backends_total)
            / max by (namespace, cluster, pod) (cnpg_pg_settings_setting{name="max_connections"})
          > 0.9
```

[../samples/monitoring/rules.yaml](../samples/monitoring/rules.yaml)

Once every connection slot is taken, PostgreSQL refuses new connections, so new client sessions fail although the database runs. A pool that keeps opening connections, or sessions that are never closed, reach that point step by step. 90 % leaves room to act before the refusals start, and 5 minutes leaves out a short burst.

## Transaction ID age at 1 billion, critical

CNPG's example `PGDatabaseXidAge` warns when a database's oldest transaction ID is more than 300 million transactions old for 1 minute. The sample's `CNPGTransactionIDWraparound` is critical at 1 billion for 15 minutes.

```yaml
      # PostgreSQL stops assigning transaction IDs at about 2.1 billion.
      - alert: CNPGTransactionIDWraparound
        expr: |
          max by (namespace, cluster) (cnpg_pg_database_xid_age) > 1000000000
          and on (namespace, cluster) cnpg_sample:database
        for: 15m
```

[../samples/monitoring/rules.yaml](../samples/monitoring/rules.yaml)

PostgreSQL stops assigning transaction IDs at about 2.1 billion, and then takes no more writes. Autovacuum starts an aggressive vacuum of a table at 200 million by default (`autovacuum_freeze_max_age`), so an age of a few hundred million is normal on a busy database and is not something a person must act on. Every alert of the sample is something to act on, mostly critical. At 1 billion, vacuum has failed to freeze old rows for a long time, and about half of the range is left. The age changes slowly, so 15 minutes costs nothing. The dashboard shows the age of each database.

## No alerts on long transactions, waiting backends or deadlocks

CNPG's example rules warn on a transaction that runs longer than 5 minutes (`LongRunningTransaction`), on backends that wait for locks (`BackendsWaiting`) and on more than 10 deadlocks in an hour (`DatabaseDeadlockConflicts`). The sample has no alert for these. Its dashboard shows the longest transaction on each instance.

```python
        [tgt(named(f"max by (namespace, pod) (cnpg_backends_max_tx_duration_seconds{{{S}}})"), "{{node}} {{role}}")],
```

[../samples/monitoring/dashboard.py](../samples/monitoring/dashboard.py)

Each of these depends on the application: a report can run for an hour by design, and some lock waits are normal. None of them means on its own that the database is down, behind or at risk of losing data, and the sample's alerts are what a person must act on. On the dashboard, the longest transaction helps explain a problem that an alert found.

## Alertmanager groups by database and alert, and mutes what follows

Alertmanager groups every alert of a route into one group unless `group_by` is set. The sample's route groups by `namespace`, `cluster` and alert name, and writes out Alertmanager's default timing (`group_wait: 30s`, `group_interval: 5m`, `repeat_interval: 4h`). Three inhibition rules mute alerts that follow from another.

```yaml
    - matchers: ['alertname=~"CNPG.+"']
      receiver: databases
      group_by: [namespace, cluster, alertname]
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
```

```yaml
  # A database that is down mutes what follows from it.
  - source_matchers: ['alertname="CNPGDatabaseDown"']
    target_matchers: ['alertname=~"CNPGReplicaDown|CNPGReplicaLag|CNPGBackupFailing|CNPGMetricsMissing"']
    equal: [namespace, cluster]
```

[../samples/monitoring/alertmanager.yaml](../samples/monitoring/alertmanager.yaml)

One notification per problem: a database's alerts of one name form one group, with one notification when it fires and one when it resolves; a pod that joins a firing group, or a warning that turns critical, sends an update. The timing is written out so the route does not change when it is copied under a root route with other values. When the database is down, its replicas, lag, backups and metrics are down too, and those alerts would only repeat it. A replica that is down mutes its own lag and missing metrics, and a critical alert mutes the warning of the same alert and object.

## The exporter is scraped over HTTPS every 5 s

Prometheus scrapes every minute over HTTP by default, and CNPG's `PodMonitor` examples scrape the metrics port without TLS. The sample's scrape uses HTTPS with the server certificate's CA and one of its names, every 5 s, and adds the labels the rules need.

```yaml
  - job_name: cnpg
    scrape_interval: 5s
    scheme: https
    tls_config:
      ca_file: /etc/otel/company-ca/ca.crt  # the CA of the server certificate
      server_name: k3s-1.example.test       # one of its dnsNames
```

[../samples/charts/cnpg-opentelemetry-collector/values.yaml](../samples/charts/cnpg-opentelemetry-collector/values.yaml), [monitoring.md](monitoring.md#scrape-targets-and-labels)

The metrics port answers only over TLS (see [Metrics over TLS](#metrics-over-tls)). `CNPGWritesBlocked` must see a wait of 10 s, so the scrape runs every 5 s, and with `metricsQueriesTTL: 0s` each scrape runs the queries anew. The `cluster` label comes from the pod label `cnpg.io/cluster` and names the database in every rule; `node` names each instance by its node on the dashboard.

## An instance counts only while its metrics arrive

An OTel collector on each node scrapes the exporters of that node. When the node is lost, its collector goes with it and sends no stale marker, so the rule evaluator keeps the instance's last samples for its lookback, 5 minutes in Prometheus. A lost primary would then still count as the primary for those 5 minutes, and `CNPGReplicaDown` would fire for it after about 10. The rules count an instance only while its newest sample is at most 30 s older than the newest of its cluster.

```yaml
      - record: cnpg_sample:instance_reports
        expr: |
          max by (namespace, cluster, pod) (timestamp(cnpg_collector_up))
            > on (namespace, cluster) group_left ()
          max by (namespace, cluster) (timestamp(cnpg_collector_up)) - 30
```

[../samples/monitoring/rules.yaml](../samples/monitoring/rules.yaml), [monitoring.md](monitoring.md#collectors)

The primary, the replicas streaming from it, the instances that answer and `CNPGReplicaDown`'s missing metrics all read it. Comparing with the cluster's newest sample, not with the evaluator's clock, keeps a slow pipeline from making every instance look lost.

## A dashboard of the sample instead of CNPG's dashboard

CNPG keeps a Grafana dashboard in its `grafana-dashboards` repository. The sample ships its own dashboard for one cluster, written by `dashboard.py`: a status strip, the state of each instance over time, then rows for workload, replication, rule checks and nodes. Its Healthy tile counts the firing critical alerts of `rules.yaml`.

```python
HEALTHY = f"count({firing('.+')}) or vector(0)"
```

[../samples/monitoring/dashboard.py](../samples/monitoring/dashboard.py), [../samples/monitoring/dashboard.json](../samples/monitoring/dashboard.json)

Red on the dashboard means that a critical alert fires, nothing else, and orange that a value passed a warning threshold. A tile that turns red on its own threshold can disagree with the alerts, and a person then does not know which to believe. Healthy stays at Yes while an alert is pending. Instances are named by the node they run on, which stays the same across failovers while pod roles change, and a lost instance shows while `CNPGReplicaDown` fires for it. The dashboard reads the chart's queries, the rules' recorded series and `ALERTS`, which CNPG's dashboard does not know. `check.sh` tests at every step of every rule test case that Healthy equals the number of firing critical alerts.

# Test cluster only

## k3s nodes in docker, three servers with embedded etcd

The test cluster runs three k3s servers as docker containers on one host, from the k3s image pinned by digest. The first starts with `--cluster-init`, the others join it, so the servers share an embedded etcd. A plain k3s install is one server with SQLite.

```bash
K3S_IMAGE=rancher/k3s@sha256:ada5ff2e138120efe877f76d514dedda65b304122112b982eab532732c028c89  # v1.33.13+k3s2
```

```bash
  local join=(--cluster-init)
  if ((i > 0)); then
    join=(--server "https://${NODE_IPS[0]}:6443")
  fi
```

[../live/lib.sh](../live/lib.sh), [../live/up.sh](../live/up.sh)

The scenarios need three nodes they can stop and start in seconds on one runner. Three servers with embedded etcd keep the API up when one node is lost, and lose it when two are, as the docs describe for a three-node cluster. The digest keeps every run on the same k3s.

## Node containers run privileged, with tmpfs and raised limits

Each node container runs `--privileged`, with tmpfs on `/run`, `/var/run` and `/tmp`, and raised `nproc` and `nofile` limits.

```bash
    --privileged --tmpfs /run --tmpfs /var/run --tmpfs /tmp \
    --ulimit nproc=65535 --ulimit nofile=65535:65535 \
```

[../live/up.sh](../live/up.sh)

k3s in a container needs to manage cgroups, mounts and iptables as on a host, and the raised limits leave room for the processes and open files of a node's pods. `/tmp` is a tmpfs because containerd tests idmapped mounts under `/tmp` at start, and they fail on docker's overlayfs; without them `hostUsers: false` pods do not start.

## k3s restarts itself inside the node container

`bench/node-init.sh` is the first process of each node container. It runs `k3s server` and starts it again 5 s after it exits.

```sh
while true; do
  status=0
  /bin/k3s server "$@" || status=$?
  echo "node-init.sh: k3s exited with code $status; starting it again in 5 s" >&2
  sleep 5
done
```

[../bench/node-init.sh](../bench/node-init.sh)

k3s's systemd unit does the same (`Restart=always`, `KillMode=process`), so a node's pods keep running while k3s is down. As a container's first process, a k3s exit would stop every pod on the node. k3s exits, for example, when it loses a leader lease because two of three nodes are gone. The script also moves itself out of the root cgroup so containerd can create cgroups below it.

## kube-proxy leaves the conntrack table size alone

The node containers start k3s with `--kube-proxy-arg conntrack-max-per-core=0`.

```bash
    --kube-proxy-arg conntrack-max-per-core=0 >/dev/null
```

[../live/up.sh](../live/up.sh)

kube-proxy sets the host's conntrack table size at start by default. In a container that write is not allowed, and kube-proxy fails to start. With 0 it leaves the size as the host has it.

## Node addresses and the API certificate

Each node gets a fixed address on the docker network `live` with `--node-ip`, and the API server's certificate lists it with `--tls-san`.

```bash
    --node-ip "$ip" --tls-san "$ip" \
```

[../live/up.sh](../live/up.sh)

The scenarios reach every node's API server by its address, with one kubeconfig per node, so that a node loss leaves the others reachable. Fixed addresses let the read probes and `pgfallback` dial each node.

## No SELinux, no secrets encryption, low ports open

The test cluster's nodes run without `--selinux` and without `--secrets-encryption`, and docker sets `ip_unprivileged_port_start` to 0 in their network namespaces. `host-check.sh` fails five checks there: `selinux`, `k3s-secrets` and `low-ports` for these reasons, `postgres-account` because the k3s image has no `getent`, and `dir-modes` because no volume was made on the node yet. CI expects exactly these failures.

```text
| `selinux` | `disabled; enable_selinux false` | The runner's kernel has no SELinux, and k3s runs without `--selinux` |
```

[host-check.md](host-check.md#known-failures-on-container-nodes)

The runners' kernel has no SELinux. Secrets encryption and the low-port threshold do not change failover, alerts or logins, which the scenarios test. `postgres-account` fails because the k3s image has no `getent`, and `dir-modes` because the node has no volume yet. `live/host-check.sh` checks that only these known failures appear.

## An S3 store next to the nodes, over plain HTTP

The test cluster's object store is versitygw in a container next to the nodes, reached inside the cluster as `s3.s3.svc:9000` over HTTP, through a Service without selector and an EndpointSlice.

```yaml
objectStore:
  endpointURL: http://s3.s3.svc:9000
```

[../live/values.yaml](../live/values.yaml), [../live/up.sh](../live/up.sh)

The scenarios break the store on purpose: they stop it so connections are refused, or pause it so it accepts connections and never answers. A store in a container on the same docker network can be broken that way in a second, and its address stays the same. The scenarios need no TLS to the store.

## A self-signed CA behind the Issuer example-ca

The test cluster creates a self-signed `Issuer`, a CA `Certificate` from it with an ECDSA P-256 key, and the CA `Issuer` `example-ca` that `values.yaml` names. The CA's certificate is also the client CA in the Secret `client-ca`.

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: example-ca
  namespace: $NS
spec:
  ca:
    secretName: example-ca
```

[../live/up.sh](../live/up.sh)

The chart needs an issuer whose CA is in the client CA Secret. A self-signed CA is the smallest issuer of that kind and needs nothing outside the cluster.

## The node names in the server certificate

The test cluster adds the three node names to the server certificate's `dnsNames`.

```yaml
replication:
  dnsNames: [pg-rw, pg-rw.databases.svc, k3s-1, k3s-2, k3s-3]
```

[../live/values.yaml](../live/values.yaml)

The `pgfallback` scenarios connect from outside the cluster with `sslmode=verify-full`, to the nodes by name, so the certificate must carry those names.

## A client certificate for orders-app.test

The test cluster issues a client certificate with the CN `orders-app.test` from `example-ca`, which logs in as `orders`.

```yaml
spec:
  secretName: live-client
  commonName: orders-app.test
  usages: [client auth]
```

[../live/up.sh](../live/up.sh)

The writer, the read probes and `pgfallback` log in as an application would, with a certificate that the chart's pg_ident maps to one role.

## Prometheus and Alertmanager in the cluster

Every scenario runs Prometheus with `rules.yaml` and Alertmanager with `alertmanager.yaml` in the namespace `otel`, on a node the scenario does not stop. Alertmanager's receiver has an address that does not exist.

```bash
PROMETHEUS_IMAGE=prom/prometheus:v3.7.3@sha256:49214755b6153f90a597adcbff0252cc61069f8ab69ce8411285cd4a560e8038
ALERTMANAGER_IMAGE=prom/alertmanager:v0.34.1@sha256:e9733bafb1bdef9b00e25a21f8f99dc26a22224bf16641ad754d1649f4c3357a
PROM_NS=otel
```

[../live/lib.sh](../live/lib.sh)

The samples' rules run outside the Kubernetes cluster. On one runner the stack runs inside it, on a node no scenario stops, which acts like an evaluator outside the database's nodes. The namespace `otel` is the one the chart's NetworkPolicy admits to 9187. The scenarios check that exactly the expected alerts fire and reach Alertmanager, so nothing has to be sent.

## One backup at the start instead of a schedule

The test cluster starts one backup after install instead of a `ScheduledBackup`.

```bash
  k cnpg backup "$CLUSTER" -n "$NS" --backup-name "$FIRST_BACKUP" \
    --method plugin --plugin-name barman-cloud.cloudnative-pg.io >/dev/null
```

[../live/up.sh](../live/up.sh)

`CNPGBackupFailing` fires when there is no backup. A cluster with scheduled backups has one; a scenario's cluster lives less than a day, so one backup at the start stands in for the schedule.

# Kept at the default

## The node grace period stays at 50 s

k3s marks a lost node unreachable after 50 s, the Kubernetes default (`node-monitor-grace-period`). Failover starts only then, so that wait is most of the minute a primary node loss costs. A shorter grace period saves time: in tests 20 s saved about 28 s. It also marks a slow node as lost: at 10 s, a network delay of 2 s made a node look lost and the primary fail over. A node marked lost by mistake costs a failover. The grace period is k3s configuration, outside the chart.

## A rollout restarts the primary in place

`primaryUpdateMethod: restart` is CNPG's default; the chart writes it out.

```yaml
  primaryUpdateMethod: restart
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml)

A rollout that changes the pods, or a parameter that needs a restart, restarts the replicas one at a time, then the primary, which stays primary: for a parameter, PostgreSQL restarts inside the running pod; for a change of the pods, CNPG recreates the pod. For a parameter that needs a restart, writes stop for about 6 s while PostgreSQL restarts, also with a pooled session open. A rollout that changes the pods stops them until the primary's new pod accepts connections.

`switchover` would move the primary to an updated replica instead. In CloudNativePG 1.30.1, the switchover of a rollout can name one replica as the target and then another a moment later. The first one keeps trying to take the primary lease. At the next switchover the primary releases the lease, that replica takes it and keeps it, and the switchover never ends, with no primary, until that replica's pod restarts. In repeated live runs this stopped 5 of 119 switchovers made right after a rollout; with `restart`, none of 144. CloudNativePG fixed it after 1.30.1 ([cloudnative-pg#11677](https://github.com/cloudnative-pg/cloudnative-pg/pull/11677)). With `restart`, a rollout makes no switchover.

After a restart inside the pod, PostgreSQL starts with CNPG's own `pg_ident` lines only. The chart's lines come back at the instance's next reconcile, which the restart itself sets off, within a few seconds. Until then replicas cannot log in with the replication certificate and client certificate logins fail, so commits wait.

## CNPG's default startup probe

CNPG's startup probe uses `pg_isready` by default: an instance is started as soon as PostgreSQL is alive. CNPG can also start an instance only once it streams from the primary within a lag limit. That check fails for every replica that restarts while the primary is lost, since it has no primary to stream from. With `failoverQuorum`, CNPG needs both replicas ready to promote, so one restarted replica would stop the failover until the old primary returned. With the default, a restarted replica is ready once it has replayed its own WAL, and the failover goes on.

## CNPG's default readiness probe, without a lag limit

An instance is ready, and its node opens the read port, once PostgreSQL accepts connections. A readiness probe that checks streaming or lag fails on every replica the moment the primary is lost, since none has a WAL receiver then. CNPG uses the same readiness for the Services and for promotion, so no replica would be ready and none would be promoted. A starting or rewound replica can therefore open the read port while it is behind, and a replica that falls behind later stays on it. `CNPGReplicaLag` watches that, and a client reads through `pg-rw` first, so while a primary exists these reads do not reach it.

## The primary isolation check stays on, with its default timeouts

CNPG's liveness probe on a primary also checks that the primary can reach the API server or another instance, and restarts PostgreSQL when it can reach neither. With one node left that runs the primary, the check restarts PostgreSQL after about 30 s, and it cannot start without the API, so reads on that node stop too. Turning the check off would keep those reads, but it would also let an old primary that is cut off from the rest keep serving reads on its node's read port while another primary takes the writes.

## No backup retention policy

The barman-cloud plugin deletes nothing from the store unless the ObjectStore has a `retentionPolicy`; its docs show 30 days as an example. The sample sets none, so nothing is deleted and the store grows. An instance that needs a WAL file a retention policy deleted cannot catch up by itself, and CNPG does not rebuild it. With a retention policy, the retention window must be longer than the longest time an instance can be down.

## local-path-provisioner runs one pod

Every other service runs one pod per node; local-path-provisioner keeps k3s's one. It has no leader election, so more copies would compete for the same volumes. On a lost node, mounted volumes keep working; only new volumes wait until Kubernetes moves the provisioner, and failover needs none.

## The plugin replaces all its pods at once on an update

The plugin chart always updates with `Recreate`, and has no value to change it. A plugin upgrade restarts all three pods at once, and CNPG reconciles nothing until a new pod answers. That stays as the chart has it, so a plugin upgrade is done when no failover is expected.

## archive_timeout stays at 5 minutes

CNPG sets `archive_timeout` to 5 minutes, so PostgreSQL switches to a new WAL file, and archives the old one, at least that often. A longer timeout would cut the WAL a quiet cluster writes, but commits would then wait longer before they reach the store, and a restore from the store alone would miss more of them. The sample makes WAL files smaller instead (1 MB), which cuts a quiet cluster's WAL from 4.5 GiB to 288 MiB a day and keeps the 5-minute bound.

## wal_compression stays off

PostgreSQL's `wal_compression` compresses full-page images inside WAL records. It does not change the size of a WAL file: a file switched by `archive_timeout` keeps its full size however little it holds. Smaller WAL files cut that, and barman-cloud already compresses each file with gzip before it uploads it.

## Superuser access stays off

`enableSuperuserAccess` is off in CNPG by default; CNPG's full example turns it on. The chart writes it out.

```yaml
  # No postgres password and no <cluster>-superuser Secret.
  enableSuperuserAccess: false
```

[../samples/charts/cnpg-cluster/templates/cluster.yaml](../samples/charts/cnpg-cluster/templates/cluster.yaml)

With it on, `postgres` gets a password and its Secret `<cluster>-superuser` sits in the namespace, which rule 2 forbids. Superuser access stays local, as `postgres` over `kubectl exec`.

## config.clusterWide stays true

The operator chart's default is `config.clusterWide: true`, and the sample keeps it.

```yaml
config:
  # true only so the chart does not write its own WATCH_NAMESPACE; RBAC is off below.
  clusterWide: true
```

[../samples/charts/cnpg-cloudnative-pg/values.yaml](../samples/charts/cnpg-cloudnative-pg/values.yaml)

With `false`, the chart writes `WATCH_NAMESPACE` as its own namespace only and renders namespaced RBAC there. The sample needs two namespaces, so it keeps `true`, turns the chart's RBAC off and sets `WATCH_NAMESPACE` itself (see [The operator watches only cnpg-system and databases](#the-operator-watches-only-cnpg-system-and-databases)).
