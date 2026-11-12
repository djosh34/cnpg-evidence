# Samples

`samples/` holds what a scenario installs, and what you install on a real cluster: k3s settings, the upstream Helm charts with a values chart each, the CNPG cluster chart, the monitoring and the scenarios. The upstream charts are cert-manager v1.21.3, `cloudnative-pg` 0.29.1 (CloudNativePG 1.30.1), `plugin-barman-cloud` 0.8.1 and `opentelemetry-collector` 0.177.0.

| Path | What |
|---|---|
| [`desired.yaml`](../samples/desired.yaml) | The cluster's desired state: name, namespace, client CA Secret, LoadBalancers, namespaces, replication certificate names, databases with their role and client CNs. The cluster chart and `evidence.sh` both read it. |
| `charts/<upstream>/` | An upstream chart as `helm pull --untar` gives it. Never edited. |
| `charts/cnpg-<upstream>/` | Its values chart: a dependency on `file://../<upstream>`, the values, and what the upstream chart does not make, such as RBAC or the collectors' client certificate. |
| [`charts/cnpg-cluster/`](../samples/charts/cnpg-cluster) | The CNPG cluster: `Cluster`, `Database`s, certificates, `ObjectStore`, `NetworkPolicy` and the queries Secret. Chart-only settings are in its `values.yaml`. |
| [`charts/company-acme/`](../samples/charts/company-acme) | A ClusterIssuer of a company CA that serves ACME. Used only by the scenarios. |
| [`charts/releases.yaml`](../samples/charts/releases.yaml) | The releases a scenario installs, in order. |
| [`values/`](../samples/values) | The scenarios' own values per release, on top of the others. `new-image.yaml` is the image the `rollout` scenario changes to. |
| [`k3s/`](../samples/k3s) | `config.yaml`, the k3s server settings of every node, and `manifests/`, which k3s applies on every server. |
| [`monitoring/`](../samples/monitoring) | Alert rules, the Alertmanager route and the Grafana dashboard ([monitoring.md](monitoring.md)). |
| [`features/`](../samples/features) | The scenarios ([e2e.md](e2e.md)). |

## Change a chart, its values or the k3s settings

A scenario installs each release of `releases.yaml` with `helm upgrade --install --wait`: the release's `values` files, then `values/<release>.yaml` when it exists.

- **A setting that production uses too:** change the values chart's `values.yaml`, or `desired.yaml` for the cluster's shape.
- **A setting only the scenarios need:** change `values/<release>.yaml`.
- **The k3s settings:** change `k3s/config.yaml`, or add a manifest to `k3s/manifests/`. The run adds each node's address, the join and the DNS server itself.
- **A new release:** add it to `releases.yaml` with `name`, `namespace` and `chart`, at the point in the order where its dependencies are installed.
- **A new upstream chart version:** compare the RBAC as [below](#rbac-on-chart-upgrades), replace the directory, and set the same version in the values chart's `Chart.yaml`; `helm dependency build` fails while the two differ.

```bash
rm -r samples/charts/<chart>
helm pull <chart> --repo <repo> --version <version> --untar --untardir samples/charts
```

Then run the scenarios that touch the change, with `./e2e.sh <scenario>` or all of them with [`e2e.yml`](e2e.md#run-scenarios-in-ci). After a change to `monitoring/`, run `bash samples/monitoring/check.sh`.

## Install on a cluster

The samples assume k3s with flannel, servicelb, local-path and the network policy controller, hosts with SELinux, and CNPG with the barman-cloud plugin. Pods with `hostUsers: false` need a kernel with idmapped mounts on tmpfs.

1. Create the namespaces `cnpg-system` and `databases`.
2. Install cert-manager as the release `cert-manager` in `cert-manager`, then create the issuer named in `charts/cnpg-cluster/values.yaml`. It must allow `client auth`, which CNPG needs on the replication certificate.
   ```bash
   helm dependency build --skip-refresh samples/charts/cnpg-cert-manager
   helm upgrade --install cert-manager samples/charts/cnpg-cert-manager -n cert-manager --create-namespace --wait
   ```
3. Set `desired.yaml`. `caSecret` is a Secret you create by hand with `ca.crt` only: the CAs that may sign client certificates, including the issuer's CA, which the chart also uses as the server CA. Pass the same file to `evidence.sh --ca`.
   ```bash
   kubectl create secret generic client-ca -n databases --from-file=ca.crt=client-ca.pem
   ```
4. Set `charts/cnpg-cluster/values.yaml`: the issuer, the object store with its credentials Secret (keys `ACCESS_KEY_ID` and `ACCESS_SECRET_KEY`), and `cluster.postgresUID` and `postgresGID`, the ids the image names `postgres`. Set `walSegmentSize` and the ids before the cluster is created.
5. Install the operator and the plugin. The release names must stay `cnpg` and `barman-cloud`: the RBAC templates and `evidence.sh` use their ServiceAccount names.
   ```bash
   helm dependency build --skip-refresh samples/charts/cnpg-cloudnative-pg
   helm upgrade --install cnpg samples/charts/cnpg-cloudnative-pg -n cnpg-system --wait
   helm dependency build --skip-refresh samples/charts/cnpg-plugin-barman-cloud
   helm upgrade --install barman-cloud samples/charts/cnpg-plugin-barman-cloud -n cnpg-system --wait
   ```
6. Install the cluster:
   ```bash
   helm upgrade --install pg samples/charts/cnpg-cluster -n databases -f samples/desired.yaml
   ```
7. Restart the instances of a cluster that existed before: `hostUsers: false` applies only to new pods.
   ```bash
   kubectl annotate cluster <cluster> -n databases kubectl.kubernetes.io/restartedAt="$(date -u +%FT%TZ)" --overwrite
   ```
8. Run one pod of each k3s service per node, as [below](#one-pod-per-node), turn on k3s secrets encryption, and install the collectors and the rules as [monitoring.md](monitoring.md#set-up) says.

The NetworkPolicy reads every node's `spec.podCIDR` with `lookup`, so `helm template` needs `--dry-run=server`, and a new node needs a `helm upgrade`. A new database is one more entry in `databases` and a `helm upgrade`. Another database namespace also needs an entry in the operator's `WATCH_NAMESPACE` and the RoleBindings of both RBAC templates.

**Existing objects.** Helm changes only what it owns. When the cluster's objects already exist, step 6 fails with `invalid ownership metadata`. Give each the label `app.kubernetes.io/managed-by=Helm` and the annotations `meta.helm.sh/release-name=pg` and `meta.helm.sh/release-namespace=databases`, or copy the parts from `helm template` into your manifests. CNPG refuses a LoadBalancer Service of the same name that it did not create; delete it before step 6.

## What the samples change, and why

Compared with each project's defaults and examples. The rule numbers are those of the [README](../README.md#rules).

| Setting | Default | Why |
|---|---|---|
| **k3s** | | |
| [Secrets encryption](https://docs.k3s.io/security/secrets-encryption) on: `--secrets-encryption` on new servers | off | The Secrets hold certificate keys and store credentials; without it they sit in plain text in etcd and its snapshots. Rule 8. |
| An audit policy, given with `--kube-apiserver-arg=audit-policy-file=` and `audit-log-path=`: level `Metadata` for `pods/exec`, `pods/attach` and `secrets` in `databases`, `None` for the rest | no audit log | Records who opened a shell next to the data or read a Secret. Ship the log off the node. |
| SELinux enforcing, with `enable_selinux` in containerd | off in containerd | Every container gets its own SELinux label. Rule 5. |
| **cert-manager** | | |
| `crds.enabled: true` | false | One install gives a working cert-manager. |
| One issuer whose CA is in `caSecret`, for every certificate | self-signed issuer | One Secret lists every CA the cluster trusts, and CNPG holds no CA key. Rule 1. |
| Server certificate with the `dnsNames` of `desired.yaml`; replication certificate with a node's host name as CN | CNPG's own CA and the CN `streaming_replica` | A company CA can sign them. The chart adds a pg_ident line for that CN. |
| No `cnpg.io/reload` label on the certificate Secrets | label on Secrets made ahead | cert-manager alone owns them. A renewal reaches PostgreSQL at CNPG's next reconcile of the cluster. |
| **Operator and plugin** | | |
| The charts' RBAC off; the values charts bind the same rules only in `cnpg-system` and `databases`; the plugin's Secrets cut to `get,list,watch` | cluster-wide | Rule 6. |
| `WATCH_NAMESPACE=cnpg-system,databases` | every namespace | The operator only watches where it has rights. |
| **One pod per node** | | See [below](#one-pod-per-node). |
| **ObjectStore** | | |
| `--read-timeout=5`, `AWS_MAX_ATTEMPTS=1` | 60 s, 5 attempts | Failover, switchover and a starting replica wait for the store. A store that never answers then costs about 5 s per call instead of about 5 minutes. 2 s failed against a working store 1 s away. |
| Credentials for this one bucket, bucket encrypted at rest | not said | The bucket holds a full copy of every database. |
| **Cluster** | | |
| Hummingbird `postgresql:18.6`, pinned by digest | CNPG's image | Minimal, pulls without a login. The scripts run only `psql` in it. |
| `postgresUID`, `postgresGID` 999 | 26 | The ids the image names `postgres`; with 26, CNPG's pg_ident line names `postgres_fedora`. |
| `hostUsers: false` through `cnpg.io/podPatch` | host's uids | A host user with uid 999 is nobody in the pod. Rule 5. |
| `storageSize: 50Gi`, `walSegmentSize: 1`, `walKeepSize: 30GB`, no replication slots | 1Gi, 16 MB, 512MB, slots | See [WAL and the object store](#wal-and-the-object-store). |
| Required anti-affinity between instances | preferred | A commit's two copies never share a node, and each node's read port has one instance. |
| `synchronous: {method: any, number: 1, dataDurability: required}`, `synchronous_commit: remote_apply`, `failoverQuorum: true` | asynchronous | See [Writes, reads and failover](#writes-reads-and-failover). |
| `smartShutdownTimeout: 0` | 180 s | A pool never closes its sessions, so a stopping primary would hold writes up to 180 s. |
| `switchoverDelay: 30` | 3600 s | With a store over TLS that never answers, the old primary took 11 minutes to stop. With 30 s, the new primary took a write after about 610 s. Unarchived WAL stays in the old primary's `pg_wal` until it rejoins. |
| Bootstrap with `database: postgres`, `owner: postgres` and a placeholder Secret | `app` database, role and Secret | Rule 4, and the `app` role logs in with a password. |
| `postInitSQL` creates `cnpg_metrics_exporter` and grants it `pg_ident_file_mappings` | none | The compliance query reads that view. |
| pg_hba: one `hostssl <db> <role> all cert map=clients` line per database, then `host all all all reject` | password line last | Rules 1 and 2. |
| pg_ident map `clients`, one exact line per client CN | none | A certificate maps to one role only. |
| Managed roles, `LOGIN` only, `disablePassword: true` | none | Rules 2 and 3. |
| One `Database` object per database | `app` | Each role reaches its own database. |
| rw LoadBalancer and optional read LoadBalancer, without NodePorts | ClusterIP Services only | See [LoadBalancers](#loadbalancers). |
| Metrics over TLS | HTTP | Rule 1. |
| Queries in the Secret `<cluster>-queries`, in `monitoring.customQueriesSecret`, with `metricsQueriesTTL: 0s` | defaults, 30 s cache | With a ConfigMap, CNPG 1.30.1 rewrites the `Cluster` status many times a second while a lost pod is marked for deletion, and every exporter loses its query metrics. Without the cache, a wait shows at the next 5 s scrape. |
| A `NetworkPolicy` for every pod of the cluster | none | See [What the chart renders](#what-the-chart-renders). |
| **Monitoring** | CNPG's example rules and dashboard | See [monitoring.md](monitoring.md). |

**Kept at the default**, though there was a reason to change it:

- **Node grace period, 50 s.** Failover starts once a lost node is marked unreachable. 20 s saved about 28 s, but at 10 s a 2 s network delay made a node look lost.
- **`primaryUpdateMethod: restart`.** With `switchover`, CloudNativePG 1.30.1 can name one target and then another; the first keeps trying for the primary lease, and the next switchover never ends. That stopped 5 of 119 switchovers after a rollout; with `restart`, none of 144. Fixed after 1.30.1 ([cloudnative-pg#11677](https://github.com/cloudnative-pg/cloudnative-pg/pull/11677)).
- **Startup and readiness probes.** A lag check would fail on every replica the moment the primary is lost, and the quorum needs both replicas ready to promote.
- **The primary isolation check.** It stops reads on a last node that runs the primary, but without it a cut-off old primary would serve stale reads.
- **No backup retention.** With a retention policy, the window must be longer than any instance can be down: an instance that needs a deleted WAL file cannot catch up by itself.
- **`archive_timeout` 5 min and `wal_compression` off.** Smaller WAL files cut a quiet cluster's WAL instead, and barman-cloud gzips each file.
- **`enableSuperuserAccess` off.** On, `postgres` gets a password Secret. Rule 2.
- **One local-path provisioner pod.** It has no leader election. Mounted volumes keep working when its node is lost.
- **The plugin's `Recreate` update.** The chart has no value for it, so upgrade the plugin when no failover is expected.

## What the chart renders

From the example `desired.yaml`:

```
pg_hba:
  hostssl orders  orders  all cert map=clients
  hostssl billing billing all cert map=clients
  host    all     all     all reject
pg_ident:
  cnpg_streaming_replica node-1.example.test streaming_replica
  clients orders-app.test     orders
  clients billing-app.test    billing
  clients billing-report.test billing
managed.roles: orders, billing (LOGIN, no other attribute, disablePassword: true)
Database objects: pg-orders, pg-billing
```

The `NetworkPolicy` selects every pod with the cluster's label, the bootstrap and join Jobs included. It admits 5432 and 8000 from the cluster's pods, 8000 from the operator, 9187 from the OTel namespace, and 5432 from outside the cluster, from the other nodes and from the rw LoadBalancer's svclb pods. Under flannel, a connection that entered through another node arrives from that node's `flannel.1` address, the network address of its pod range, so each is admitted as a `/32`.

## LoadBalancers

k3s servicelb opens each LoadBalancer's port on every node.

- **rw, 5432:** every node forwards it to the primary.
- **read, `readLoadBalancer.port`:** `selectorType: r` with `externalTrafficPolicy: Local`. A node forwards it only to its own instance, primary or replica, while that instance is ready. A node without one refuses the port, so a client moves on at once.

Neither opens a NodePort. The read LoadBalancer still has a `healthCheckNodePort`, which answers over HTTP and does not lead to PostgreSQL. A client outside the cluster uses rw first and the read port only while no rw address takes a connection; [pgfallback](https://github.com/djosh34/pgfallback) does that for pgx and GORM.

## Writes, reads and failover

- Every commit waits until one other instance has applied it. When none can confirm, writes stop instead of going on with one copy. A commit whose wait was cancelled may still be committed, so treat a cancelled COMMIT as unknown.
- CNPG promotes a replica only when it can tell that it holds every confirmed commit. With two replicas it needs both ready to decide.
- An instance is ready, and its node opens the read port, once PostgreSQL accepts connections. A starting or rewound replica can serve reads while it is still behind; `CNPGReplicaLag` watches that.

What clients see, with all three nodes in the host list:

- **A replica's node is lost.** Reads go on elsewhere; writes go on.
- **The primary's node is lost.** Reads go on on the replicas. Writes fail until CNPG promotes a replica, about 75 s after the loss: most of it is Kubernetes noticing the lost node. With an operator and a plugin pod on every node, a lost leader's lease passes on within about 20 s.
- **A node comes back.** Its instance opens the read port about 30 s after the node starts; an old primary rewinds first. After a large backlog it can serve reads that miss recent commits for some seconds.
- **A rollout** for a parameter that needs a restart stops writes for about 6 s. PostgreSQL then starts with CNPG's own pg_ident lines only; the chart's lines return at the instance's next reconcile, within seconds, and until then commits wait.
- **A switchover** stops writes for about 11 s.
- **A former primary that rewinds onto an idle primary** can wait for that primary's next WAL record before it accepts connections. One write ends the wait.
- **One node left.** With embedded etcd, two lost servers mean no Kubernetes API, so nothing is promoted and writes stop. A last replica keeps serving reads. A last primary is restarted by its isolation check after about 30 s and cannot start without the API. When the nodes return, everything recovers by itself.
- **A replica restarts while the primary's node is down.** It is ready once it has replayed its own WAL, and the quorum then promotes.

## WAL and the object store

- **No replication slots.** A slot keeps WAL for a replica without a limit, so one that stays away fills the primary's disk. Instead, every instance keeps `walKeepSize` of WAL, and a replica further behind reads the rest from the store by itself.
- **`walKeepSize: 30GB`**, on the data volume, so `storageSize` must hold it plus the data. That is about three months of a quiet cluster's WAL.
- **`walSegmentSize: 1`.** A switched WAL file keeps its full size, so a quiet cluster writes 288 MiB a day instead of 4.5 GiB. Each file is one call to the store, so archiving keeps up only below about 2.5 MB/s of WAL; WAL not yet archived is never removed, and `CNPGDataDiskFull` warns at 70 %. Fixed when the cluster is created.

Commits and reads never wait for the store. A promotion, a switchover and a starting replica do. From the event until the new primary took a write:

Against the times [above](#writes-reads-and-failover) for a working store:

| Store | Primary node loss | Switchover |
|---|---|---|
| Refuses connections | about 80 s | about 17 s |
| Accepts connections and never answers, over TLS | about 9 min | about 10 min |
| Drops connections without an answer | about 10 min | about 14 min |

The last two wait in the TLS handshake or the connect, which ends only at botocore's connect timeout of 60 s; barman-cloud has no option for it. A former primary with WAL the store never got waits for the store before it rejoins.

## One pod per node

Every service the cluster relies on runs one pod on each node, so a lost node takes none with it; Kubernetes moves a lost node's pods only after 5 minutes. Leader-elected services hand their lease to another pod.

| Service | How |
|---|---|
| CNPG operator, barman-cloud plugin, cert-manager's three components | Their values charts: 3 replicas, required anti-affinity by host name, and `maxSurge: 0`, since an extra pod has no node to go to. |
| CoreDNS | `kubectl scale deployment coredns -n kube-system --replicas=3` |
| metrics-server | The patch below |
| Traefik | Put `k3s/manifests/traefik-config.yaml` into `/var/lib/rancher/k3s/server/manifests/` on every server |

```bash
kubectl patch deployment metrics-server -n kube-system --type=merge -p '{
  "spec": {"replicas": 3, "template": {"spec": {"affinity": {"podAntiAffinity": {
    "requiredDuringSchedulingIgnoredDuringExecution": [{
      "topologyKey": "kubernetes.io/hostname",
      "labelSelector": {"matchLabels": {"k8s-app": "metrics-server"}}}]}}}}}}'
```

k3s's manifests set neither field, so both hold across k3s restarts.

## Compliance metric

The chart's query reports `cnpg_compliance_violations{rule, check}` on every instance: what breaks each check, 0 when it passes.

| `rule` | `check` | Counts |
|---|---|---|
| 1 | `unexpected_role` | Roles other than `postgres`, `streaming_replica`, `cnpg_metrics_exporter`, those of `desired.yaml` and `app` |
| 4 | `app_role` | The role `app` |
| 3 | `role_attribute` | Each special attribute or `pg_*` file or data role a role holds, but `postgres`, and replication for `streaming_replica` |
| 1 | `cn_mapping` | pg_ident lines that are extra, missing or unreadable |

`CNPGComplianceViolation` and `CNPGMetricsMissing` watch it ([monitoring.md](monitoring.md#alerts)). A cluster the chart did not create lacks the two grants the query needs; give them once on its primary:

```bash
kubectl exec -n databases <primary pod> -c postgres -- psql -U postgres \
  -c 'GRANT SELECT ON pg_ident_file_mappings TO cnpg_metrics_exporter' \
  -c 'GRANT EXECUTE ON FUNCTION pg_ident_file_mappings() TO cnpg_metrics_exporter'
```

## Restore into a new cluster

```bash
helm install pg-restore samples/charts/cnpg-cluster -n databases -f samples/desired.yaml \
  --set cluster.name=pg-restore --set recovery.enabled=true --set recovery.sourceCluster=pg \
  --set rwLoadBalancer.name=pg-restore-rw-lb --set readLoadBalancer=null
```

The new name gives its WAL archive its own folder. CNPG refuses a Service another cluster owns, so the restore gets its own rw LoadBalancer and none for reads; while the old cluster holds 5432, use its `pg-restore-rw` Service inside the cluster. A backup taken before `app` was removed brings `app` back: [remove it](#remove-app-from-a-cluster-bootstrapped-with-the-defaults) again. A backup taken before the chart's grants needs the [compliance grants](#compliance-metric) given again.

## Remove app from a cluster bootstrapped with the defaults

In this order:

1. Set `bootstrap.initdb` (or `recovery`) to `database: postgres`, `owner: postgres`, `secret.name: <cluster>-bootstrap`, and apply that Secret from `templates/bootstrap-secret.yaml`.
2. `kubectl delete secret <cluster>-app -n <namespace>`
3. `kubectl exec -n <namespace> <primary pod> -c postgres -- psql -U postgres -c 'DROP DATABASE app' -c 'DROP ROLE app'`. If the role owns objects in other databases, run `REASSIGN OWNED BY app TO postgres; DROP OWNED BY app;` in each first.

## RBAC on chart upgrades

The values charts replace the upstream RBAC. A rule they lack shows as `forbidden` in the operator or plugin log. Before an upgrade, render the upstream RBAC, then again after it, and compare:

```bash
helm template cnpg samples/charts/cloudnative-pg -n cnpg-system \
  --set config.clusterWide=false --show-only templates/rbac.yaml > cnpg-rbac.yaml
helm template barman-cloud samples/charts/plugin-barman-cloud -n cnpg-system \
  --show-only templates/rbac.yaml --show-only templates/additional-rbac/leader_election.yaml > barman-rbac.yaml
# After the upgrade, the same two commands into cnpg-rbac-new.yaml and barman-rbac-new.yaml, then:
diff -I helm.sh/chart: -I app.kubernetes.io/version: cnpg-rbac.yaml cnpg-rbac-new.yaml
diff -I helm.sh/chart: -I app.kubernetes.io/version: barman-rbac.yaml barman-rbac-new.yaml
```

The operator's ClusterRole maps to `cnpg-operator-cluster` and its Role to `cnpg-operator-namespaced`. The plugin's ClusterRole maps to `barman-cloud-namespaced`, which keeps Secrets cut to read, and a resource it watches cluster-wide also needs `list,watch` in `barman-cloud-cluster`.

## The scenarios' cluster

The scenarios differ from production only here:

- Three k3s servers with embedded etcd as privileged containers, with tmpfs on `/run`, `/var/run` and `/tmp` (containerd tests idmapped mounts under `/tmp`), and `conntrack-max-per-core=0`, since kube-proxy cannot set it in a container.
- No SELinux and no secrets encryption, and docker opens low ports, so `host-check.sh` fails four checks, as [`host-check.feature`](../samples/features/host-check.feature) lists.
- The company CA, the store and the client run as containers next to the nodes, and the company CA approves only the node names.
- One backup at the start stands in for a schedule, since a scenario's cluster lives less than a day.
