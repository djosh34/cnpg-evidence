# Samples

What is in `desired.yaml` and `samples/`, how to install it, and how to keep it right. The commands below pin the operator chart `cloudnative-pg` 0.29.1 and the plugin chart `plugin-barman-cloud` 0.8.1.

## Files

| File | What it is |
|---|---|
| [`desired.yaml`](../desired.yaml) | The desired state of the cluster: name, namespace and instances, the client CA Secret, the rw LoadBalancer name, the optional read LoadBalancer's name and port, the operator and OTel namespaces, the replication certificate names, and the databases with their role and client CNs. `evidence.sh` compares against it; the chart reads it as values. |
| [`samples/chart/`](../samples/chart) | A Helm chart that renders the `Cluster`, one `Database` per database, the server and replication `Certificate`s, the `<cluster>-bootstrap` Secret, the barman-cloud `ObjectStore`, one ingress `NetworkPolicy` and the `<cluster>-queries` Secret. |
| [`samples/chart/values.yaml`](../samples/chart/values.yaml) | Chart-only settings: image, PostgreSQL's uid and gid, storage size, WAL file size and how much WAL to keep, cert-manager issuer, object store and its timeouts, recovery. |
| [`samples/values-cnpg-operator.yaml`](../samples/values-cnpg-operator.yaml) | Values for the operator chart: chart RBAC off, `WATCH_NAMESPACE=cnpg-system,databases`, one pod per node. |
| [`samples/values-barman-cloud.yaml`](../samples/values-barman-cloud.yaml) | Values for the plugin chart: chart RBAC off, one pod per node. |
| [`samples/values-cert-manager.yaml`](../samples/values-cert-manager.yaml) | Values for the cert-manager chart: its CRDs, one pod of the controller, the webhook and the CA injector per node. |
| [`samples/traefik-config.yaml`](../samples/traefik-config.yaml) | A k3s `HelmChartConfig` that runs k3s's Traefik as a DaemonSet. |
| [`samples/rbac-cnpg-operator.yaml`](../samples/rbac-cnpg-operator.yaml) | The operator's RBAC: a small ClusterRole for nodes, webhook configurations and cluster image catalogs, and the chart's namespaced rules bound only in `cnpg-system` and `databases`. |
| [`samples/rbac-barman-cloud.yaml`](../samples/rbac-barman-cloud.yaml) | The plugin's RBAC: cluster-wide `list,watch` on object stores, roles and role bindings, and the chart's other rules bound only in `databases`, with Secrets cut to `get,list,watch`. |
| [`samples/monitoring/`](../samples/monitoring) | Alert rules and an Alertmanager configuration for the cluster, used outside it (see [monitoring.md](monitoring.md)). |

## What the chart renders

From the example `desired.yaml`:

```
pg_hba:
  hostssl orders  orders  all cert map=clients
  hostssl billing billing all cert map=clients
  host    all     all     all reject
pg_ident:
  cnpg_streaming_replica pg-replication streaming_replica
  clients orders-app.test     orders
  clients billing-app.test    billing
  clients billing-report.test billing
managed.roles: orders, billing (LOGIN, no other attribute, disablePassword: true)
Database objects: pg-orders, pg-billing
```

- Each `hostssl ... cert map=clients` line lets one role into one database with a client certificate; `clients` maps each CN to its role. The last line rejects every other TCP connection, with or without TLS.
- `cnpg_streaming_replica` is CNPG's map for replication logins; the chart adds the replication CN to it.
- The server and replication `Certificate`s carry the replication CN and `dnsNames` from `desired.yaml`, and the issuer from `values.yaml`.
- The `NetworkPolicy` selects every pod of the cluster, including its bootstrap and join Job pods, and admits 5432 and 8000 from the cluster's pods, 8000 from the operator pods, 9187 from the OTel namespace, and 5432 from outside the cluster, from the other nodes and from the svclb pods of the rw LoadBalancer.
- The `<cluster>-queries` Secret holds the queries that the metrics exporter runs on every instance: the compliance query (see [Compliance metric](#compliance-metric)), and the replica lag and the commits that wait for a standby, which the alerts of [monitoring.md](monitoring.md) read. The `Cluster` lists it in `monitoring.customQueriesSecret`. A Secret rather than a ConfigMap: with a Secret listed there, CNPG 1.30.1 does not rewrite the `Cluster` status many times a second while a lost pod is marked for deletion, which would leave every instance's exporter without its query metrics until the node returns.
- The `Cluster` has the rw LoadBalancer and, when `readLoadBalancer` is set, the read LoadBalancer, both without NodePorts (see [LoadBalancers](#loadbalancers)). Every commit waits for one other instance, and a rollout moves the primary with a switchover (see [Writes, reads and failover](#writes-reads-and-failover)).

To see the full output: `helm template pg samples/chart -n databases -f desired.yaml --dry-run=server`. The NetworkPolicy reads every node's `spec.podCIDR` from the cluster with `lookup`, so rendering without a cluster fails. A NetworkPolicy written by hand needs the same pod ranges, from `kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'`: each range goes into the `except` list of the `0.0.0.0/0` source, and its network address as `/32` becomes a source of its own. Under flannel, connections from another node itself arrive from that address, the node's `flannel.1` interface. No address range is fixed in the samples or the scripts.

## Install

Pods with `hostUsers: false` need a kernel with idmapped mounts on tmpfs.

1. Create the namespaces and apply both RBAC files:
   ```bash
   kubectl create namespace cnpg-system
   kubectl create namespace databases
   kubectl apply -f samples/rbac-cnpg-operator.yaml -f samples/rbac-barman-cloud.yaml
   ```
2. Install cert-manager in the namespace `cert-manager` with the release name `cert-manager`: `evidence.sh` expects the ServiceAccounts `cert-manager` and `cert-manager-cainjector` there.
   ```bash
   helm upgrade --install cert-manager cert-manager --repo https://charts.jetstack.io --version v1.21.3 \
     -n cert-manager --create-namespace -f samples/values-cert-manager.yaml --wait
   ```
   Create the issuer named in `samples/chart/values.yaml`. Check that it accepts the `usages` in `templates/certificates.yaml`; CNPG needs `client auth` on the replication certificate.
3. In `desired.yaml`, set:
   - `cluster`: the name, namespace and number of instances. The namespaces `databases` and `cnpg-system` are also fixed in `values-cnpg-operator.yaml` (`WATCH_NAMESPACE`) and in both RBAC files. Another namespace also needs `WATCH_NAMESPACE` and the RoleBindings in both RBAC files.
   - `caSecret`: a Secret in the cluster's namespace with `ca.crt` holding the CAs that may sign client certificates, including the CA of the `issuer` in `values.yaml`: the chart also uses this Secret as the server CA, and the replication certificate is checked against it. Give the full chain if there are intermediates. Create it by hand, never with `ca.key`: `kubectl create secret generic client-ca -n databases --from-file=ca.crt=client-ca.pem`. Pass the same file to `evidence.sh --ca`.
   - `rwLoadBalancer.name`: the rw LoadBalancer Service. The policy admits its svclb pods, the per-node pods in `kube-system` through which k3s servicelb forwards the LoadBalancer port.
   - `readLoadBalancer`: the name and port of the read LoadBalancer, or leave the block out for none.
   - `network.operatorNamespace`, `network.otelNamespace`: the namespaces of the operator and the OTel collectors.
   - `replication`: the CN and `dnsNames` of the server and replication certificates; `databases`: the databases, their roles and client CNs.
4. In `samples/chart/values.yaml`, set:
   - `issuer`: the cert-manager issuer from step 2, which signs the server and replication certificates.
   - `objectStore`: the bucket, endpoint and credentials Secret. Create that Secret in the cluster's namespace with the keys `ACCESS_KEY_ID` and `ACCESS_SECRET_KEY`.
   - `cluster.imageName`: the PostgreSQL image. The default is Red Hat's Hummingbird image `registry.access.redhat.com/hi/postgresql:18.6`, pinned by digest, which pulls without a login. It has bash, coreutils and `psql`, but no `openssl`. The scripts in `scripts/` run only `psql` in it, always with `-U postgres`.
   - `cluster.postgresUID` and `cluster.postgresGID`: the uid and gid PostgreSQL runs as, which the chart passes to the `Cluster`'s `postgresUID` and `postgresGID`. Each must be the uid and gid the image names `postgres`: 999 in the Hummingbird image, the default. CNPG writes the name of the uid into pg_ident; with CNPG's own default 26, which this image names `postgres_fedora`, the compliance metric and `evidence.sh` find wrong pg_ident lines. Give `host-check.sh` and `prove.sh` the same values with `--postgres-uid` and `--postgres-gid`. Set them when the cluster is created.
   - `cluster.storageSize`, `cluster.walSegmentSize` and `cluster.walKeepSize`: the data volume of each instance, the size of each WAL file, and how much WAL every instance keeps (see [WAL and the object store](#wal-and-the-object-store)). The volume must hold `walKeepSize` plus the data. Set `walSegmentSize` before the cluster is created.
5. Install the operator and the plugin with their values files:
   ```bash
   helm upgrade --install cnpg cloudnative-pg --repo https://cloudnative-pg.github.io/charts --version 0.29.1 \
     -n cnpg-system -f samples/values-cnpg-operator.yaml --wait
   helm upgrade --install barman-cloud plugin-barman-cloud --repo https://cloudnative-pg.github.io/charts --version 0.8.1 \
     -n cnpg-system -f samples/values-barman-cloud.yaml --wait
   ```
   To install from a file instead, fetch it with `helm pull cloudnative-pg --repo https://cloudnative-pg.github.io/charts --version 0.29.1`, the same for `plugin-barman-cloud`, and give the `.tgz` path in place of the chart name and `--repo`.
   Both values files run one pod per node (see [One copy of every service per node](#one-copy-of-every-service-per-node)).
   The release names must stay `cnpg` and `barman-cloud`: the RBAC files name their ServiceAccounts `cnpg-cloudnative-pg` and `barman-cloud-plugin-barman-cloud`, and `evidence.sh` asks about those names.
6. Install the chart: `helm upgrade --install pg samples/chart -n databases -f desired.yaml`.
7. Restart the instances. The chart sets `hostUsers: false` through the `cnpg.io/podPatch` annotation on the `Cluster`, which applies only to new pods, so pods that already run keep sharing the host's uids. Start a rolling restart, then check that every instance pod has `hostUsers: false` (`evidence.sh` checks it too):
   ```bash
   kubectl annotate cluster <cluster> -n databases kubectl.kubernetes.io/restartedAt="$(date -u +%FT%TZ)" --overwrite
   kubectl get pods -n databases -l cnpg.io/cluster=<cluster>,cnpg.io/podRole=instance \
     -o custom-columns=NAME:.metadata.name,HOSTUSERS:.spec.hostUsers
   ```
8. Point the OTel collectors at `https://<pod address>:9187/metrics`, with the CA of the server certificate as `ca_file` and one of its `dnsNames` as `server_name`. Add the labels that [monitoring.md](monitoring.md#scrape-targets-and-labels) lists, which its alert rules need.
   Run the collectors without `hostNetwork`, in the OTel namespace.
   If a collector does use `hostNetwork`, run it with `securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}`; otherwise it can bind a port below 1024 on its node.

CNPG creates both LoadBalancer Services and refuses a Service of the same name that it did not create (`refusing to reconcile service: ..., not owned by the cluster`). Delete such a Service before step 6; its port is closed until CNPG has made the new one.

Helm changes only objects it owns. When the cluster's objects already exist, step 6 fails with `invalid ownership metadata` for each of them, such as the `Cluster`, the `NetworkPolicy` or a `Certificate`. Either let Helm take them over: give each the label `app.kubernetes.io/managed-by=Helm` and the annotations `meta.helm.sh/release-name=pg` and `meta.helm.sh/release-namespace=databases`, after checking with `helm template` that the chart renders the same names (the replication `Certificate` is `<cluster>-replication`). Or copy the parts from the `helm template` output into the existing manifests by hand.

## LoadBalancers

k3s servicelb opens each LoadBalancer's port on every node:

- **rw, 5432:** every node forwards it to the primary.
- **read, `readLoadBalancer.port`:** with `selectorType: r` and `externalTrafficPolicy: Local`, a node forwards it only to the instance on that node, primary or replica, and only while that instance is ready. A node without a ready instance refuses the port, so a client moves on to the next node at once. Connections keep the client's address, which the policy admits as outside on 5432; the read LoadBalancer needs no entry of its own.

Both set `allocateLoadBalancerNodePorts: false`, so neither opens a NodePort. The read LoadBalancer still has a `healthCheckNodePort`: Kubernetes gives one to every LoadBalancer with traffic policy Local. It answers over HTTP how many ready instances the node has and does not lead to PostgreSQL.

A NodePort that a Service had before keeps working after a chart upgrade: Kubernetes keeps a NodePort it has allocated, and CNPG does not remove it. Remove it once by hand, then check that `kubectl get svc -n databases` shows no second port for the Service:

```bash
kubectl patch service pg-rw-lb -n databases --type=json -p '[{"op":"remove","path":"/spec/ports/0/nodePort"}]'
```

### Clients on the read port

A client outside the cluster uses rw on 5432 of every node and turns to the read port only while no rw address takes a connection. For pgx and GORM, the package `pgfallback` does that; [pgfallback.md](pgfallback.md) shows how, with the connection string to use.

## Writes, reads and failover

The chart's settings in the `Cluster`:

- **`synchronous: {method: any, number: 1, dataDurability: required}`.** Every commit waits until one of the other instances has it. When no other instance can confirm, writes stop instead of going on with one copy.
- **`synchronous_commit: remote_apply`.** The commit returns only once that instance has applied it, so a read there right after the commit sees it.
- **`failoverQuorum: true`.** CNPG promotes a replica only when it can tell that the replica holds every confirmed commit. With one confirming copy and two replicas, it needs both replicas ready to decide.
- **`primaryUpdateMethod: switchover`.** A rollout that changes the pods, or a parameter that needs a restart, restarts the replicas one at a time, then switches over to one of them and restarts the former primary as a replica. One case still restarts the primary in place: lowering `max_connections`, `max_worker_processes`, `max_wal_senders`, `max_prepared_transactions` or `max_locks_per_transaction`, which a replica must not have lower than the primary. With this setting CNPG also refuses a change of `imageName` together with a change of PostgreSQL parameters; apply them one after the other.
- **No replication slots, and WAL kept on every instance.** See [WAL and the object store](#wal-and-the-object-store).
- **`smartShutdownTimeout: 0`.** A stopping instance ends open sessions at once instead of waiting up to 180 s for them to close, which a connection pool does not do by itself. A commit that is still waiting for its standby then ends with the warning that it committed locally but might not have been replicated. It stays committed.
- **Startup, readiness and liveness checks are CNPG's defaults.** An instance is ready, and its node opens the read port, once PostgreSQL accepts connections, so a failover never waits on a lag check. A starting or rewound replica can therefore open the read port while it is still behind the primary, and a replica that falls behind later stays on the read port; watch its replication lag. A client reads through `pg-rw` first and turns to the read port only when no primary answers, so while a primary exists these reads do not reach it. The liveness isolation check stays on.

What clients see, from tests on a three-node k3s cluster with these settings, a new connection every 0.25 s and all three nodes in the host list:

- **A replica's node is lost.** Reads keep working on the other nodes. Writes go on without a pause.
- **The primary's node is lost.** Reads keep working on the replicas. Writes fail until CNPG has promoted a replica, about a minute after the loss, up to about a minute and a half when the lost node also ran the leader of the Kubernetes controller manager. Most of that time is Kubernetes noticing that the node is gone and the old primary's lease running out. The node does not need to come back. With one operator and one plugin pod on every node, a lost node's operator or plugin pod does not hold this up: another pod takes over their leader lease within about 20 s.
- **A node comes back.** Its instance opens the read port about half a minute after the node starts. An old primary first rewinds itself and comes back as a replica. After a large backlog the instance can open the read port before it has caught up: after a node was down while 1.2 GB of WAL was written, its read port served reads that missed recent commits for 16 s, and a former primary that rewound under steady writes did so for 14 to 42 s.
- **A rollout or a switchover.** Writes stop for about 11 s while the primary moves, also with a pooled session open. Reads keep working on every node whose instance is not restarting.
- After each of these, every replica caught up fully by itself.

An open connection ends when the node it entered through stops, when its instance is promoted, and when its instance stops in a rollout or a switchover.

A former primary that rewinds onto a new primary that writes nothing can wait for the new primary's next WAL record before it accepts connections. Until then it stays not ready, so its node refuses the read port, and CNPG does not fail over again automatically, since the quorum needs both replicas ready. The next write ends the wait within seconds, so a cluster that takes writes does not stay in it.

### One node left

With embedded etcd, two of three servers lost means no Kubernetes API, so nothing is promoted and nothing changes in the cluster until a second node returns. Writes stop, as every commit needs a second instance.

- **The last node runs a replica.** It keeps serving reads on its read port, with the data as it was when the other nodes were lost.
- **The last node runs the primary.** Writes hang. After about 30 s the isolation check finds neither the API nor the other instances, and the liveness probe restarts PostgreSQL, which cannot start again without the API. Reads stop too. If k3s itself exits on that node first, which it can when it held one of the k3s leader leases, nothing restarts PostgreSQL: under systemd the running containers keep going and keep serving reads.
- **When both nodes return,** everything recovers without a manual step.

### A replica restart while the primary's node is down

A replica whose container restarts while the primary's node is down, after a crash or an OOM kill of PostgreSQL, is ready again once it has replayed its own WAL and accepts connections. It needs no primary for that. The quorum then sees both replicas and CNPG promotes the one that holds every confirmed commit, as after any primary loss, only some seconds later.

## WAL and the object store

The chart keeps enough WAL on the instances' own disks that a replica that was down rarely needs the object store, and it limits how long a broken store can hold up a failover or a switchover.

- **No replication slots** (`replicationSlots.highAvailability.enabled: false` in the `Cluster`). A slot keeps WAL on the primary for its replica until the replica returns, without a limit, so an instance that stays away fills the primary's disk. Without slots the primary keeps `wal_keep_size` of WAL, and an instance that is further behind reads the rest from the object store by itself.
- **`cluster.walKeepSize`: 30GB** (`wal_keep_size`). Every instance keeps up to that much recent WAL in `pg_wal`, on its data volume, so `cluster.storageSize` (50Gi by default) must hold it plus the data. A replica that was down catches up from the primary without the store as long as the primary still has the WAL it needs. A quiet cluster writes about 288 MiB of WAL a day, so 30GB is about three months; writes add their own WAL.
- **`cluster.walSegmentSize`: 1**, WAL files of 1 MB instead of PostgreSQL's 16 MB. PostgreSQL switches to a new WAL file at least every 5 minutes (CNPG's `archive_timeout`), and a switched file keeps its full size. A quiet cluster then writes 288 MiB of WAL a day instead of 4.5 GiB. The size is set only when a cluster is created: a new value does not change a running cluster, and a restore keeps the size of its backup. Each file is one call to the store, so the archive keeps up only while the primary writes less than about 2.5 MB/s; above that, WAL waits in `pg_wal` until the archive catches up. WAL that is not archived yet is never removed, so a primary that writes faster for hours grows `pg_wal` past `walKeepSize` until the volume is full and PostgreSQL stops; `CNPGDataDiskFull` warns at 70 %. With 1 MB files, initdb also sets `max_wal_size` to 64 MB, so a primary under load makes a checkpoint every 64 MB of WAL.
- **`objectStore.readTimeout`: 5 and `objectStore.maxAttempts`: 1.** The ObjectStore passes `--read-timeout=5` to every WAL archive and restore call and sets `AWS_MAX_ATTEMPTS=1` for barman-cloud in the plugin's sidecar. With barman-cloud's defaults, a store that accepts connections and never answers holds each call for about 5 minutes: a 60 s read timeout and 5 attempts. With these settings it ends after about 5 s. Two cases stay at about 60 s per call, because barman-cloud sets no connect timeout and has no option for one: a 1 MB upload to a store that never answers, and any call to a store that drops connections without an answer. Against a working store 1 s away, 5 s never failed; 2 s did.

Commits and reads never wait for the store. A failover, a switchover and a starting replica do: a promotion looks up the timeline history and the last WAL file in the store, a starting replica asks the store first for each WAL file it replays, and the old primary in a switchover tries to archive once more before it stops.

What a broken store costs, in seconds from the event until the new primary took a write, measured on a three-node k3s cluster with these settings. The refusing and the never answering store are the `store-refuse` and `store-hang` scenarios of [live.md](live.md); the last row comes from a test whose store dropped every new connection.

| Store | Primary node loss | Switchover |
|---|---|---|
| Works | about 75 | about 11 |
| Refuses connections | about 80 | about 17 |
| Accepts connections and never answers | about 120 | about 90 |
| Drops connections without an answer | about 600 (10 min) | about 850 (14 min) |

With the store refusing, a replica that was down while 1.2 GB of WAL was written caught up from the primary alone, about 40 s after its node started. A former primary with WAL that the store never got waits for the store before it rejoins: CNPG archives that WAL before the former primary rewinds. Until the store is back, the cluster runs on the other two instances, and every commit needs both.

**Backup retention.** The sample sets no retention policy, so nothing is deleted from the store. With a retention policy, the retention window must be longer than the longest time an instance can be down: an instance that needs a WAL file the policy deleted cannot catch up by itself, and CNPG does not rebuild it.

**The node grace period.** k3s marks a lost node unreachable after 50 s, the Kubernetes default, and failover starts only then, so that wait is most of the minute a primary node loss costs. The sample keeps it: in tests a 20 s grace period saved about 28 s, and at 10 s a network delay of 2 s made a node look lost and the primary fail over. The grace period is k3s configuration, outside the chart.

## Compliance metric

The chart gives CNPG's metrics exporter a compliance query, which it runs on every instance as `cnpg_metrics_exporter`. Port 9187 then reports `cnpg_compliance_violations`, one series per instance and check. Each value counts what breaks the check on that instance; 0 means it passes.

| `rule` | `check` | Counts |
|---|---|---|
| 1 | `unexpected_role` | Roles other than `postgres`, `streaming_replica`, `cnpg_metrics_exporter` and the roles in `desired.yaml`, besides `app` |
| 4 | `app_role` | The role `app` |
| 3 | `role_attribute` | Each role and attribute it should not have: superuser, create roles, create databases, replication or bypass row security, and membership in `pg_read_server_files`, `pg_write_server_files`, `pg_execute_server_program` or `pg_read_all_data`. A role has an attribute when it can `SET ROLE` to a role that has it, and a membership also by inheritance. Only `postgres` holds them, and `streaming_replica` replication. |
| 1 | `cn_mapping` | The instance's pg_ident lines that are not expected or that PostgreSQL cannot read, and the expected lines that are missing. The expected lines are CNPG's own and those of the chart, so each client CN maps only to its own role. |

The `rule` label is the rule `evidence.sh` reports the same finding under. Two alerts of [monitoring.md](monitoring.md) watch it:

- `CNPGComplianceViolation`, on `cnpg_compliance_violations > 0`: a role, an attribute or a mapping changed. `evidence.sh` shows which.
- `CNPGMetricsMissing`, when an instance that answers reports fewer than the four checks: the query failed, for example without the grants below, or the exporter returns no query metrics. An instance that is not scraped is `CNPGReplicaDown`.

The chart sets `metricsQueriesTTL: 0s` in the `Cluster`, so every scrape runs the queries and a change shows at the next scrape. The query cannot see passwords; `evidence.sh` checks them. `evidence.sh` counts writing Secrets or ConfigMaps in the cluster's namespace as PostgreSQL superuser, and `evidence.sh` against `desired.yaml` remains the full check.

### Grants

Reading `pg_ident_file_mappings` needs two grants for `cnpg_metrics_exporter`. On a new cluster, the chart's `postInitSQL` gives them. CNPG creates `cnpg_metrics_exporter` only after that SQL, so the chart creates the role first, as CNPG would; CNPG then keeps it and adds `pg_monitor`.

On a cluster that already runs, give them once on the primary. Replicas get them by replication:

```bash
kubectl exec -n databases <primary pod> -c postgres -- psql -U postgres \
  -c 'GRANT SELECT ON pg_ident_file_mappings TO cnpg_metrics_exporter' \
  -c 'GRANT EXECUTE ON FUNCTION pg_ident_file_mappings() TO cnpg_metrics_exporter'
```

A restore copies the grants with the rest of the catalog when the backup was taken after them. After a restore from an older backup, run the same step on the new cluster's primary. Until then the metric is missing.

`evidence.sh` expects exactly these grants: `can_read_ident_view` and `can_run_ident_function` must each list `postgres` and `cnpg_metrics_exporter`, no other role.

## Outside the chart

### One copy of every service per node

Every service the cluster relies on runs one pod on each of the three nodes, so a lost node takes no service with it. A single copy on the lost node holds things up: CNPG reconciles a cluster, failover included, only while the barman-cloud plugin answers, and Kubernetes starts a lost node's pods elsewhere only after 5 minutes. The leader-elected services, the operator, the plugin, cert-manager's controller and CA injector, run one active pod; when its node is lost, another pod takes over the lease.

| Service | How |
|---|---|
| CNPG operator | `samples/values-cnpg-operator.yaml`: 3 replicas with required pod anti-affinity by host name, and updates with `maxSurge: 0`, since an extra pod has no node to go to |
| barman-cloud plugin | `samples/values-barman-cloud.yaml`: 3 replicas with the same anti-affinity. The chart always updates with `Recreate`, so a plugin upgrade restarts all three pods at once, and CNPG reconciles nothing until a new one answers |
| cert-manager | `samples/values-cert-manager.yaml`: 3 replicas each of the controller, the webhook and the CA injector, with anti-affinity and `maxSurge: 0` |
| CoreDNS | `kubectl scale deployment coredns -n kube-system --replicas=3`. k3s's manifest spreads its pods by host name and sets no replica count, so the count holds across k3s restarts as long as a k3s version does not add one |
| Traefik | Put `samples/traefik-config.yaml` into `/var/lib/rancher/k3s/server/manifests/` on every server; k3s then runs its Traefik as a DaemonSet |
| metrics-server | The patch below. k3s's manifest sets neither replicas nor affinity, so the change holds across k3s restarts |
| local-path-provisioner | One pod: it has no leader election, so more copies would compete. On a lost node, mounted volumes keep working; only new volumes wait until Kubernetes moves it, and failover needs none |

```bash
kubectl patch deployment metrics-server -n kube-system --type=merge -p '{
  "spec": {"replicas": 3, "template": {"spec": {"affinity": {"podAntiAffinity": {
    "requiredDuringSchedulingIgnoredDuringExecution": [{
      "topologyKey": "kubernetes.io/hostname",
      "labelSelector": {"matchLabels": {"k8s-app": "metrics-server"}}}]}}}}}}'
```

Until Kubernetes marks a lost node unreachable, about 50 s, its CoreDNS pod stays in the DNS Service, so about one in three DNS lookups in the cluster times out in that time. Failover waits for the same mark, so this does not delay it.

`live/up.sh` installs every service this way and checks the placement (see [live.md](live.md)).

### Secrets encryption

By default k3s stores Secrets unencrypted in etcd and in its etcd snapshots. Turn on k3s `secrets-encryption`: `--secrets-encryption` on new servers, or the `k3s secrets-encrypt` steps on a running cluster ([k3s docs](https://docs.k3s.io/security/secrets-encryption)). Snapshots taken before stay unencrypted.

### Audit log

The k3s API server writes no audit log by default, so a `kubectl exec` into an instance pod leaves no record. A short policy records who opened a shell in, attached to, or read a Secret in the cluster's namespace (`databases` here), without the Secret's content:

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

Give it to every server with `--kube-apiserver-arg=audit-policy-file=<path>` and `--kube-apiserver-arg=audit-log-path=<path>`, and keep the log off the node.

### Backup bucket

The bucket holds every database's WAL and base backups. Give the credentials in `objectStore.credentialsSecret` access to this one bucket only, and turn on encryption at rest for the bucket.

## Changes later

- A new database is one more entry under `databases` and a `helm upgrade`.
- A new node needs a `helm upgrade` too: the NetworkPolicy lists every node's pod range and tunnel address.
- A second database namespace needs both RoleBindings there and an entry in `WATCH_NAMESPACE`, which restarts the operator.

## Restore into a new cluster

The same chart restores from the barman-cloud backups instead of running initdb. Use a new cluster name, so that its WAL archive goes to its own folder:

```bash
helm install pg-restore samples/chart -n databases -f desired.yaml \
  --set cluster.name=pg-restore --set recovery.enabled=true --set recovery.sourceCluster=pg \
  --set rwLoadBalancer.name=pg-restore-rw-lb --set readLoadBalancer=null
```

The restore gets its own rw LoadBalancer and no read LoadBalancer: CNPG refuses a Service that another cluster owns. While the old cluster holds 5432, the new LoadBalancer's svclb pods stay Pending, so check the restore through its pods or its `pg-restore-rw` Service inside the cluster.

`bootstrap.recovery` gets the same `database`, `owner` and `secret` fields as `initdb`, so CNPG creates no `app` either. A restore still copies what the backup holds: a backup taken before `app` was removed brings the `app` database and role back. After such a restore, run steps 3 and 4 of the next section on the new cluster. A backup taken before the [compliance metric's grants](#grants) lacks them; give them on the new cluster.

## Remove app from a cluster bootstrapped with the defaults

A cluster bootstrapped with CNPG's defaults has an `app` database, an `app` role and a `<cluster>-app` Secret. Do these steps in this order: dropping `app` before step 1 breaks the instance manager's reconcile and the metrics.

1. Change the three bootstrap fields on the running `Cluster`. The CNPG webhook accepts this after bootstrap. Use the section the cluster was bootstrapped with:
   ```yaml
   bootstrap:
     initdb:
       database: postgres
       owner: postgres
       secret:
         name: <cluster>-bootstrap
   ```
   Apply the `<cluster>-bootstrap` Secret from `templates/bootstrap-secret.yaml` at the same time (username `postgres`, empty password). Keep it: CNPG writes its empty password onto `postgres`, which PostgreSQL stores as no password.
2. Delete the old Secret. The operator no longer recreates it:
   ```bash
   kubectl delete secret <cluster>-app -n <namespace>
   ```
3. Drop the database and the role as `postgres` over `kubectl exec`:
   ```bash
   kubectl exec -n <namespace> <primary pod> -c postgres -- psql -U postgres -c 'DROP DATABASE app' -c 'DROP ROLE app'
   ```
   If `DROP ROLE` reports objects or privileges in other databases, first run `REASSIGN OWNED BY app TO postgres; DROP OWNED BY app;` in each of them.
4. Check: `kubectl get secret <cluster>-app -n <namespace>` reports NotFound, and `select rolname from pg_roles where rolname = 'app'` and `select datname from pg_database where datname = 'app'` return no rows.

## RBAC on chart upgrades

The operator and plugin charts do not render RBAC here, so a new chart version can need a rule that the RBAC files lack. It then shows as `forbidden` in the operator or plugin log. Before each chart upgrade, render the RBAC of the old and the new version and compare. To work from `.tgz` files, give their paths in place of the chart name and `--repo`.

```bash
OLD=0.29.1 NEW=<new version>
for v in "$OLD" "$NEW"; do
  helm template cnpg cloudnative-pg --repo https://cloudnative-pg.github.io/charts --version "$v" \
    -n cnpg-system --set config.clusterWide=false --show-only templates/rbac.yaml >"cnpg-rbac-$v.yaml"
done
diff -I helm.sh/chart: -I app.kubernetes.io/version: "cnpg-rbac-$OLD.yaml" "cnpg-rbac-$NEW.yaml"

OLD=0.8.1 NEW=<new version>
for v in "$OLD" "$NEW"; do
  helm template barman-cloud plugin-barman-cloud --repo https://cloudnative-pg.github.io/charts --version "$v" \
    -n cnpg-system --show-only templates/rbac.yaml --show-only templates/additional-rbac/leader_election.yaml >"barman-rbac-$v.yaml"
done
diff -I helm.sh/chart: -I app.kubernetes.io/version: "barman-rbac-$OLD.yaml" "barman-rbac-$NEW.yaml"
```

No output means no RBAC change; the two `-I` options hide the version labels. Where a changed rule goes:

- Operator: the chart's ClusterRole `cnpg-cloudnative-pg` maps to `cnpg-operator-cluster`, its Role `cnpg-cloudnative-pg` to `cnpg-operator-namespaced`. At 0.29.1 both match the chart rule for rule.
- Plugin: the chart's ClusterRole `barman-cloud-plugin-barman-cloud` maps to `barman-cloud-namespaced`. At 0.8.1 the only difference is that Secrets lose `create` and `delete`; keep that cut. A resource the plugin watches at cluster scope also needs `list,watch` in `barman-cloud-cluster`.
- Plugin leader election: the chart renders this Role and RoleBinding even with RBAC off, so they are not in the RBAC file. They give only leader election rights in `cnpg-system`.
