# The bench

The bench runs one scenario of the feature files in [`samples/features/`](../samples/features) on a new three-node k3s cluster, built from the charts in [`samples/`](../samples). The host needs only docker:

```bash
docker run --rm --privileged -v "$PWD/samples:/bench:ro" -v "$PWD/results:/results" \
  ghcr.io/djosh34/cnpg-evidence-bench:<tag> switchover
```

- The argument is the tag of one scenario, without the `@`.
- `/bench` is the mounted directory, mounted read-only. The bench never writes into it.
- `/results` is optional. When it is mounted, the run writes a new directory `<scenario>-<time>` there, owned by the owner of the mounted directory: `cucumber.json` and `junit.xml` of the scenario, `always.cucumber.json` and `always.junit.xml` of `always.feature`, `timing.md`, `client.log` and the cluster's state in `state.txt`.
- `--rm` matters: the run's disk is a volume of the container, and `--rm` removes it with the container. A run that passed, failed or was killed then leaves no container, volume or network on the host.
- Exit code 0: the scenario passed. 1: it failed. 2: it could not run.

The images are public, tagged `sha-<commit>` by the [`bench` workflow](../.github/workflows/bench.yml) for amd64 and arm64.

## The host's inotify limit

Each k3s node takes many inotify instances, and `fs.inotify.max_user_instances` is the host's limit for every container. The bench needs at least 1024. At start it checks the limit and, when it is lower, stops with a message. It never changes the limit itself. [`bench/host.sh`](../bench/host.sh) raises it to 1024 until the next reboot:

```bash
bash bench/host.sh
```

## What a run does

1. Checks the inotify limit.
2. Makes an ext4 filesystem of 40 GB in a sparse file and starts its own dockerd on it, so every host gives the cluster the same empty disk.
3. Starts, through testcontainers-go, the containers outside k3s, on one network at fixed addresses:
   - `dns`: CoreDNS, which names every container below.
   - `acme.example.test`: OpenBao as the company CA. The run makes a new root. OpenBao serves ACME with an EAB key required, checks each name with http-01, and signs only the approved names, the nodes and the client, for server and client auth.
   - `s3.example.test`: versitygw with TLS, with a certificate of that CA.
   - The monitoring, as [Monitoring](#monitoring) says: `otel.example.test`, `prometheus.example.test`, `alertmanager.example.test` and `grafana.example.test`.
4. Starts three k3s servers with embedded etcd, `k3s-1.example.test` to `k3s-3.example.test`, one after another. Each runs [`bench/node-init.sh`](../bench/node-init.sh), which starts k3s again when it exits, so the pods outlive k3s as on a VM. Each gets [`k3s/config.yaml`](../samples/k3s/config.yaml) and the files of `k3s/manifests/`.
5. Runs one CoreDNS and metrics-server pod per node, as [samples.md](samples.md) says.
6. Makes the Secrets that only the run knows: the EAB key and CA of the company CA, `client-ca`, the store's CA `s3-ca`, and `backup-creds`.
7. Installs the releases of [`charts/releases.yaml`](../samples/charts/releases.yaml) in order: `helm dependency build --skip-refresh` on the chart, then `helm upgrade --install --wait` with the release's values files and `values/<release>.yaml`. The charts are copied out of the mounted directory first.
8. Waits until the cluster is healthy, takes a first backup, as a cluster with scheduled backups has one, and waits until it is done and Prometheus has the metrics of every source. Then it names the instances: the primary, replica 1 and replica 2.
9. Runs the scenario with godog. At its first When line it starts the client.
10. Runs [`always.feature`](../samples/features/always.feature), also after a failed scenario, prints the timing table and, after a failure, the cluster's state.

## The mounted directory

| Path | What |
|---|---|
| `k3s/config.yaml` | The k3s server settings of every node. |
| `k3s/manifests/` | Manifests k3s applies on every server, such as the Traefik settings. |
| `charts/<upstream>/` | An upstream chart, as `helm pull --untar` gives it. Never edited. |
| `charts/cnpg-<upstream>/` | Its values chart: a dependency on `file://../<upstream>`, the values, and what the upstream chart does not make: the RBAC that replaces the chart's, or the collectors' client certificate. |
| `charts/cnpg-cluster/`, `charts/company-acme/` | Charts of this repository: the CNPG cluster, and the ClusterIssuer of the company CA. |
| `charts/releases.yaml` | The releases in install order. |
| `desired.yaml` | The cluster's values, which `evidence.sh` also compares against. |
| `monitoring/` | `rules.yaml`, `alertmanager.yaml` and `dashboard.json`, which the containers outside k3s load. |
| `values/` | The bench's own values, per release, on top of the others. `values/new-image.yaml` is the second instance image that `rollout` changes to. |
| `features/` | The scenarios. |

## Monitoring

As [monitoring.md](monitoring.md) describes it. Inside k3s, the release `otel` of [`charts/cnpg-opentelemetry-collector`](../samples/charts/cnpg-opentelemetry-collector) runs a collector per node and one for cert-manager, each sending OTLP with mTLS to `otel.example.test:4317`. Outside k3s, as containers next to the nodes:

| Container | What |
|---|---|
| `otel.example.test` | The upstream OTel service: OTLP over gRPC with a certificate of the company CA, client certificates of that CA only, handed to Prometheus by remote write with every metric name and label as the scrape gave it. |
| `prometheus.example.test` | The rule evaluator, with `monitoring/rules.yaml`. It scrapes nothing; the metrics come by remote write. |
| `alertmanager.example.test` | With `monitoring/alertmanager.yaml` as it is. Its receiver, `https://alerts.example.com/hook`, is the bench itself, on the network's gateway with a certificate of the company CA. |
| `grafana.example.test` | With `monitoring/dashboard.json` and a Prometheus data source. |

The bench queries Prometheus, Alertmanager and Grafana over their HTTP APIs. A scenario starts once the first backup is done and Prometheus has, for each instance, the four compliance checks and its data disk, and the chart's two certificates.

## The client

The client image is the application host: a container outside k3s, `orders-app.test`. It gets its own certificate from the company CA by ACME, with its own EAB key. Then it reads and writes through [pgfallback](pgfallback.md) for the whole scenario: a query and an insert every 0.25 s, each allowed 10 s, against the rw port 5432 of the three nodes, and their read port 5433 when no rw address takes a connection. Each TCP connect may take 500 ms, within `connect_timeout=2` (see [A short dial timeout](pgfallback.md#a-short-dial-timeout)). It logs in as `orders` with `verify-full`. The bench reads only its log. A scenario with `Given no writes` starts it without writes. `When writing stops` stops the writes while the reads go on; the line ends once every write the client started has ended, so no write is acknowledged after it.

## How a scenario reads

Most lines are `<thing> is <word>`. The bench cuts a line into thing, word and limit, replaces each role with `<role>` and each number with `<n>`, and looks the result up in the vocabulary in [`bench/vocab.go`](../bench/vocab.go). A line that is not in it fails the run.

| Line shape | What the bench does |
|---|---|
| `<thing> is <word>` | An event: does it. A state: checks it now. A measure: checks it over the whole scenario. |
| `<thing> is <word> < N s` | A state: waits up to N s from the line above. A measure: its limit. |
| `<thing> is <word> < N s after the <event>` | A state: waits until N s after that event. `writing is healthy`: waits until N s after that event for an acknowledged write that the client sent after it. |
| `<thing> is <word> for N s` | A state: checks it for N s. |
| `<thing> has been <word> since the <event>` | Checks the whole time from that event to now. |
| `<thing> starts / stops / runs / passes` | The same lookup. |
| `N s pass`, `N s pass after the <event>` | Waits. |
| `<ALERT> fires / resolves for <role> < N s` | Waits up to N s until the alert fires, or no longer fires. Without a limit: checks now. |
| `<ALERT> fired / has not fired for <role>` | Checks whether it fired since the scenario started. |
| `<ALERT> may fire for <role>` | Allows it. |
| `Alertmanager gets <ALERT> for <role>` | Sends Alertmanager the critical alert for 2 min, as the rule evaluator would. An event. |
| `Alertmanager sends / mutes <ALERT> for <role> < N s` | Waits up to N s until the bench got a notification of it firing, or Alertmanager holds it suppressed. |
| `no writes` | The client does not write in this scenario. |

An event comes only in a Given or When line, a check only in a Given or Then line. Roles: **the primary**, **replica 1** and **replica 2**, named when the cluster is ready; **the new primary**, the instance that became primary last; **another instance**, any instance but the primary; **a replica**, an instance other than the one that became primary last.

| Line | Means |
|---|---|
| `the cluster is healthy` | Three ready instances, the phase healthy, two replicas streaming from the primary. |
| `<role> is primary`, `<role> is still primary` | The instance is the cluster's current primary, out of recovery. |
| `<role> is promoted` | `kubectl cnpg promote`. Its event is "the promote". |
| `no instance is promoted` | The cluster's target primary is still the primary: no promotion has started. |
| `<role>'s node is killed`, `<role>'s node and <role>'s node are killed` | `docker stop -t 0` of the nodes the instances run on, as lost VMs. The bench then uses the API server of a node that runs. Its event is "the kill". |
| `the node starts`, `the nodes start` | `docker start` of the killed nodes. Its event is "the start". |
| `<role>'s postgres container is killed` | `crictl stop --timeout 0` of the instance's postgres container on its node, as when PostgreSQL crashes; the kubelet starts it again. |
| `<role>'s postgres container is running` | The container runs again after the kill. |
| `<role> is fenced`, `<role> is unfenced` | `kubectl cnpg fencing on` and `off`. Their events are "the fence" and "the unfence". |
| `<role> is down` | PostgreSQL on the instance takes no connection. |
| `the chart's pg_ident lines are on <role>`, `... on every instance` | The instance, or every instance, has the pg_ident lines every instance had at the scenario's first such line, the chart's `clients` lines included. |
| `the instance image is changed` | `helm upgrade` of the cluster's release with its values and `values/new-image.yaml`. Its event is "the change". |
| `every instance is on the new image` | Every instance's postgres container runs the image of `values/new-image.yaml` and is ready. |
| `wal_keep_size is set to <n>MB` | `helm upgrade` of the cluster's release with its values and that `cluster.walKeepSize`. Its event is "the change". |
| `wal_keep_size is <n>MB on every instance` | `show wal_keep_size` gives it on every instance. |
| `<n> MB of WAL is written on <role>` | Rows of about 1 KB, then a truncate, on the instance until it has written that much WAL. An instance that is down then needs the WAL file the instance was writing when it started. |
| `the WAL <role> needs is gone from <role>` | After two checkpoints, that WAL file is no longer in the second instance's `pg_wal`. |
| `<role> is caught up` | The instance streams and has replayed the primary's WAL up to where it was a moment before. The timing table gives how far behind it was when its pod turned ready. |
| `<role>'s WAL is switched` | `pg_switch_wal()` on the instance. |
| `<role>'s WAL is archived` | The instance has archived the WAL file it switched away from. |
| `<role>'s WAL is waiting for the store` | The instance has WAL files marked `.ready` that wait for the store. |
| `the store is stopped`, `the store is paused` | Stopped, the store refuses connections: a container that listens on no port takes its address. Paused, `docker pause` of the store: it takes connections and never answers. |
| `the store starts` | The stopped or paused store is back. |
| `a backup is taken`, `the backup is done` | `kubectl cnpg backup` through the barman-cloud plugin, and its phase completed. Its event is "the backup". |
| `pg-restore is restored from the store` | `helm install` of the cluster's chart with its values as `pg-restore`, restored from the cluster's backups, as [samples.md](samples.md#restore-into-a-new-cluster) says. Its event is "the restore". |
| `pg-restore is healthy` | As `the cluster is healthy`, for `pg-restore`. |
| `compliance on pg-restore is healthy` | Every instance of `pg-restore` reported each of the four compliance checks as 0 in the last 30 s. |
| `the catalog is read on <role>` | `select count(*)` of every catalog table of every database on the instance. |
| `<role> is idle after a WAL switch` | The instance's insert position is 40 bytes, a page header, past its flush position at the start of a WAL file, for 30 s: no WAL since a switch. |
| `a row is written` | One insert on the primary, outside the client. |
| `writing stops` | The client stops writing; the reads go on. |
| `reading is healthy < N s` | The longest time without a successful read of the client, from its first, is under N s. |
| `writing is healthy < N s` | The longest time without an acknowledged write of the client, from its first until the writes stop, is under N s. |
| `writing has been down since the <event>` | No write the client sent since that event was acknowledged. |
| `no acknowledged write is lost` | Stops the client. Every write it got acknowledged is in `bench_writes` on the primary. |
| `no acknowledged write is lost in pg-restore` | After `writing stops`: every write the client got acknowledged is in `bench_writes` on the primary of `pg-restore`. |
| `the alerts are healthy` | No alert fires. Every alert the scenario says `fired` or `fires` fired since the scenario started, and no other did, but those it says `may fire`. |
| `the dashboard is healthy` | Grafana has the dashboard, and every panel's queries, with the dashboard's variables set to the database, give at least one value through Grafana's data source. |
| `the exporters are healthy` | Every instance's exporter answered in the last 30 s with `cnpg_compliance_violations` of the check `cn_mapping` and `cnpg_pg_replication_in_recovery`. |
| `the exporters of <role> and <role> have been healthy since the <event>` | In every 15 s in which one of their exporters answered, at least one answer had both of those metrics, and none went 60 s without answering. |

`always.feature` runs after every scenario, with the same steps. A scenario's own `writing is healthy < N s` line sets N for that scenario there too; every other limit of `always.feature` holds for every scenario.

## Building the images

From the repository root:

```bash
docker build -f bench/Dockerfile --target client -t <client image> .
docker build -f bench/Dockerfile --target bench --build-arg CLIENT_IMAGE=<client image> -t <bench image> .
```

The bench's own docker pulls the client image, so it must be in a registry the bench can reach.
