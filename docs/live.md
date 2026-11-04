# Live scenarios

The scripts in `live/` start the samples on a three-node k3s cluster in docker and run scenarios against it: nodes lost, a replica restart during a primary loss, a rollout, switchovers, a fence, a broken object store, a backup and restore, replicas that rejoin from the WAL the primary keeps or from the store, a replica that stops streaming, a replica that falls behind and commits that wait, the evidence scripts, and the `pgfallback` package from outside the cluster during a drain and node losses. Each failure scenario checks that the cluster recovers by itself, that writes come back in time, that no acknowledged commit is lost and that exactly the expected alerts fire, and writes its times to the job summary. The `live` workflow runs them on GitHub's runners, one job and one cluster per scenario.

## Files

| File | What it is |
|---|---|
| [`live/up.sh`](../live/up.sh) | Starts the cluster and installs the samples (see [The cluster](#the-cluster)) |
| [`live/node-init.sh`](../live/node-init.sh) | The first process of each node container: runs k3s and starts it again when it exits |
| [`live/values.yaml`](../live/values.yaml) | The chart values on top of `desired.yaml`: the S3 store's address, and the node names in the server certificate's `dnsNames` |
| [`live/lib.sh`](../live/lib.sh) | Functions the scenarios share: bounded waits, the cluster's state, the client, the monitoring stack, the checks and the summary |
| [`live/client/`](../live/client) | The writer and the read probes, a small Go program (see [The writer and the read probes](#the-writer-and-the-read-probes)) |
| [`live/scenarios.txt`](../live/scenarios.txt) | The list of scenarios |
| [`live/scenarios/`](../live/scenarios) | One script per scenario |
| [`live/store.sh`](../live/store.sh) | The steps of `store-refuse` and `store-hang`, which differ only in how the store breaks |
| [`live/pgfallback.sh`](../live/pgfallback.sh) | The steps of the three `pgfallback-*` scenarios, which differ only in the event (see [pgfallback from outside the cluster](#pgfallback-from-outside-the-cluster)) |
| [`live/pgfallback/`](../live/pgfallback) | The application of the `pgfallback-*` scenarios and its report, a Go module of its own |
| [`live/plan.sh`](../live/plan.sh) | Turns the workflow's `scenarios` input into the list of jobs |
| [`live/after-failure.sh`](../live/after-failure.sh) | Prints the cluster's state after a failed scenario |
| [`live/host-check.sh`](../live/host-check.sh) | Runs `host-check.sh` on one k3s node in docker and checks that only the known failures of a container node fail; the `ci` workflow runs it (see [host-check.md](host-check.md#known-failures-on-container-nodes)) |
| [`live/release-check.sh`](../live/release-check.sh) | The first job of `release.yml`: fails unless the tag's commit passed every scenario, with and without the writer |
| [`.github/workflows/live.yml`](../.github/workflows/live.yml) | The `live` workflow |

## The cluster

`live/up.sh` takes about 8 minutes on a runner. It starts:

- Three k3s servers with embedded etcd, as the docker containers `k3s-1` to `k3s-3` on the docker network `live` (`10.77.0.0/24`, nodes at `.11` to `.13`). The k3s image is pinned by digest. In each container `live/node-init.sh` runs k3s and starts it again 5 s after it exits, as k3s's systemd unit does, so the node's pods keep running while k3s is down. k3s exits, for example, on the last node when two of three are gone.
- An S3 store, versitygw in the container `s3` at `10.77.0.20`, with the bucket `example-bucket`. Inside the cluster it is `s3.s3.svc:9000`. A scenario breaks it in one of two ways: it refuses connections (the container stops, and the container `s3-refuse` with nothing listening takes its address), or it accepts them and never answers (the container is paused).
- cert-manager from `samples/values-cert-manager.yaml`, and in `databases` a self-signed CA behind the Issuer `example-ca`, the issuer that `samples/chart/values.yaml` names. Its certificate is also the client CA in the Secret `client-ca`.
- The CNPG operator and the barman-cloud plugin from `samples/values-cnpg-operator.yaml`, `samples/values-barman-cloud.yaml` and both RBAC files.
- `samples/chart` as release `pg` in `databases`, with `desired.yaml` and `live/values.yaml`. The instances run the chart's default image, the Hummingbird PostgreSQL image pinned by digest, as uid and gid 999.
- One pod of every service on every node, as [samples.md](samples.md#one-copy-of-every-service-per-node) says. `up.sh` checks that CoreDNS, Traefik, metrics-server, the cert-manager controller, webhook and CA injector, the operator and the plugin each run one ready pod on each of the three nodes, and that local-path-provisioner runs one.

It also builds `live/client`, installs `kubectl cnpg` 1.30.1 (pinned by checksum) into `$LIVE_WORK/bin`, starts a first backup to the store, as a cluster with scheduled backups has one, and writes a client certificate for `orders-app.test`, which logs in as `orders`, into `$LIVE_WORK/certs`. `$LIVE_WORK` is `/tmp/live` by default and also holds a kubeconfig for each node's API server and the client's logs. The scripts use only those kubeconfigs, never the caller's `KUBECONFIG`.

Every wait in `live/` has a limit and fails with a message that says what it waited for.

## The writer and the read probes

`live/client` logs in like an application: as `orders` to the database `orders`, with the client certificate, `sslmode=verify-ca`, all three node addresses in the host list and a `connect_timeout` of 2 s.

- **The writer** keeps one pooled connection to the rw LoadBalancer on 5432 and inserts one row into `live_writes` every 0.25 s, each with its own number. Each attempt may take 5 s. It logs every acknowledged commit with the address of the instance that took it.
- **The read probes** open a new connection to the read port 5433 of each node once per second and log whether that node's instance answered.

A scenario runs the writer when `WRITER` is `on`, the default. With `WRITER=off` it writes nothing until the event is over, then makes one write through the rw LoadBalancer, which must succeed. The read probes run in both modes.

## The monitoring stack

Every scenario runs the samples' monitoring, as [monitoring.md](monitoring.md) describes it, in the namespace `otel`, which the chart's NetworkPolicy admits to the metrics port:

- Prometheus with `samples/monitoring/rules.yaml`, scraping every instance's exporter every 5 s with the scrape of [monitoring.md](monitoring.md#scrape-targets-and-labels), the kubelets and their cAdvisor, and cert-manager.
- Alertmanager with `samples/monitoring/alertmanager.yaml`, which gets Prometheus's alerts. Its receiver's address does not exist, so it sends nothing.

Both run on a node the scenario does not stop, as a rule evaluator outside the database's nodes would. Before the event the scenario waits until Prometheus has every instance's query metrics, the data disks and the chart's two certificates, and the first backup is done.

Each scenario lists the alerts it expects, by alert and instance, and the alerts it allows: alerts that are true when they fire, but whether they fire depends on how long a step of the event takes compared with the alert's waiting time, such as `CNPGWritesBlocked` while a new primary waits for a standby. At its end every alert must have resolved within 3 minutes, every expected alert must have fired since the stack started, and no other alert but the allowed ones. Then every query of `samples/monitoring/dashboard.json`, with the dashboard's variables set to the cluster, must return data for each panel. The summary lists the alerts that fired.

## Scenarios

Each scenario first waits until all three instances are ready and the primary streams to both replicas, and starts the monitoring stack. Then, in both modes:

- Every instance must be ready and streaming again within 10 minutes of the event's end, and then every node's read port must answer within a minute.
- Every acknowledged commit, the final write included, must be in `live_writes` on the primary afterwards.
- The job summary gives, in seconds after the event, when each node's read port was down and back, and when every instance was ready and streaming.

With the writer, a scenario also fails when there was no acknowledged write for more than 180 s after the event started, and the summary gives the first write on a new primary and the longest time without a write. `rollout` allows only 30 s. `fence` and `one-node-left` stop writes on purpose, and `store-refuse` and `store-hang` may take up to 15 min, so they allow longer. The table says how long.

Without the writer, a former primary that rewound onto an idle new primary can wait for the primary's next WAL record (see [samples.md](samples.md#writes-reads-and-failover)). When not every instance is back after 10 minutes, the scenario makes its one write then, and every instance must be back within 10 s of it. The summary says so.

`quiet-rewind` always runs without the writer, also in a run with the writer on, since it tests a cluster with no writes. The `pgfallback-*` scenarios run their own application in both modes, since its queries and writes are what they test; the mode starts or leaves out only the writer.

| Scenario | Event | Checks |
|---|---|---|
| `primary-node-loss` | The primary's node stops with `docker stop -t 0` and starts again 120 s later. | Another instance becomes primary within 10 min of the stop; with the writer, it takes a write within 180 s of the stop. |
| `replica-node-loss` | A replica's node stops with `docker stop -t 0` for 6 min. | The primary stays where it is. |
| `switchover` | `kubectl cnpg promote` to a replica. | The replica becomes primary within 5 min; with the writer, it takes a write within 180 s. |
| `replica-restart-during-primary-loss` | The primary's node stops with `docker stop -t 0`; 10 s later, before any promotion, a replica's `postgres` container is killed on its node with `crictl stop --timeout 0`, and the kubelet starts it again. The node starts again 120 s after the stop. | The container runs again within 5 min; another instance becomes primary within 10 min of the stop; with the writer, it takes a write within 180 s of the stop. |
| `rollout` | `shared_buffers` changes on the `Cluster`, which needs a restart of every instance; once that is done, `kubectl cnpg promote` to a replica. | The rollout ends within 10 min with every instance on the new value, ready and streaming, with the chart's `pg_ident` lines, and the primary restarted in place on the same instance; the replica becomes primary within 5 min. With the writer, writes stop for at most 30 s at any time; the summary gives the longest stop in each of the two. |
| `fence` | `kubectl cnpg fencing on` the primary, and `fencing off` 30 s later. | PostgreSQL on the primary stops within 2 min. Within 10 min of the unfence its `pg_ident` lines equal a replica's again and every instance is ready and streaming; the primary stays where it is. With the writer, writes may stop for those 30 s plus 10 min. The summary gives when the lines came back. |
| `quiet-rewind` | `kubectl cnpg promote` to a replica, with no writes. | The replica becomes primary within 5 min. If the former primary is not back within 10 min, the one write must bring it back within 10 s. |
| `one-node-left` | The primary's node and a replica's node stop with `docker stop -t 0` and start again 120 s later. | The last node's read port answers every probe while the two nodes are down. With the writer, no write is acknowledged then, writes may stop for those 120 s plus 180 s, and the primary takes a write within 180 s of the start. |
| `replica-down-long` | A replica's node stops with `docker stop -t 0`, and the primary writes at least 1.2 GB of WAL. 360 s after the stop the store starts refusing connections and the node starts. | The replica streams and has replayed the primary's WAL within 10 min of the start, with the store still refusing; then the store comes back. The summary gives how many MB behind the replica was when its pod turned ready, which opens its node's read port. |
| `store-refuse`, `store-hang` | Twice, the store breaks and the primary switches WAL twice, so WAL waits for the archive; then the event. First the primary's node stops with `docker stop -t 0` and starts again 120 s later; then `kubectl cnpg promote` to a replica. The store comes back 60 s after the node started, and in the switchover 60 s after the new primary took over. | After each event, within 15 min, another instance is primary with a standby streaming from it; with the writer, it takes a write. With the writer, writes stop for at most 15 min. The summary gives the times of both events. |
| `backup-restore` | `kubectl cnpg backup` to the store; the client stops 30 s after it completed, and the primary switches WAL and archives it. Then the chart restores a new cluster `pg-restore` from the store, as [samples.md](samples.md#restore-into-a-new-cluster) says. | The backup completes within 10 min. `pg-restore` has three ready instances with two streaming replicas within 15 min, every acknowledged commit, and `cnpg_compliance_violations` 0 for each of its 4 checks on every instance. |
| `rejoin-from-archive` | With `wal_keep_size` set to 64MB by `helm upgrade`: a replica's node stops, the primary writes 256 MB of WAL and makes checkpoints until the WAL file it wrote at the stop is gone from its `pg_wal`, and the node starts. Then the same with the primary's node: once another instance is primary, it writes 256 MB until its WAL file of the moment it took over is gone. | Both rejoin from the store: every instance is ready and streaming within 10 min of each start. With the writer, the new primary takes a write within 180 s. |
| `replica-not-streaming` | A firewall rule in a replica pod's network namespace rejects its connections to 5432, and the primary ends its WAL sender; its exporter keeps answering. The rule goes once the alert fires. | `CNPGReplicaDown` fires for the replica within 8 min while Prometheus still gets its metrics, and resolves within 2 min after the replica streams again. |
| `exporter-node-loss` | A replica's node stops with `docker stop -t 0` for 400 s, then the primary's node for 400 s: each longer than the 5 min after which Kubernetes marks the lost pod for deletion. Each node stops only once every exporter's last answer has both `cnpg_compliance_violations` and `cnpg_pg_replication_in_recovery`: the check's first 15 s reach back before the stop, and the instance whose node just came back can answer without them for a few seconds after its pod is ready. While `CNPGReplicaDown` fires for the lost replica, the scenario sends Alertmanager `CNPGMetricsMissing` for that replica and for another instance. | For each instance that is left, in every 15 s in which its exporter answers, at least one answer has the chart's `cnpg_compliance_violations` and CNPG's `cnpg_pg_replication_in_recovery`, and the exporter never goes 60 s without answering. Within 60 s of every instance being back, every exporter answers with both; the summary gives each instance's answers without them and its failed scrapes. `CNPGReplicaDown` fires for each lost instance and reaches Alertmanager, which mutes `CNPGMetricsMissing` for the lost replica and not for the other. The primary stays where it is while the replica's node is down. |
| `lag-and-stall` | Replay pauses on a replica and the primary commits a row; once the alert fires, replay resumes. Then one transaction on the primary runs a 15 s statement and commits. Then replay pauses on both replicas, so a commit on the primary waits for a standby to apply it; once the alert fires, replay resumes. These commits are made in both modes. | `CNPGReplicaLag` fires for the replica within 5 min, reaches Alertmanager and resolves within 2 min of the resume. The 15 s statement does not fire `CNPGWritesBlocked`. The stalled commit fires `CNPGWritesBlocked` for the primary within 2 min, reaches Alertmanager, succeeds after the resume, and the alert resolves within 2 min. |
| `lag-after-primary-change` | `kubectl cnpg promote` to a replica; then `kubectl cnpg fencing on` the new primary and `fencing off` 30 s later. | After each, once every instance is ready and streaming, every replica's `cnpg_replica_lag_seconds` stays under 1 s for 330 s, longer than the 5 min of false lag CNPG's `cnpg_pg_replication_lag` showed. `CNPGReplicaLag` does not fire. The summary gives the most each metric reported. |
| `pgfallback-drain` | `kubectl drain` of the primary's node with `--ignore-daemonsets --delete-emptydir-data`, which moves the primary; `kubectl uncordon` once the drain is done. | Another instance becomes primary; the `pgfallback` checks below. |
| `pgfallback-primary-node-loss` | The primary's node stops with `docker stop -t 0` and starts again 120 s later. | Another instance becomes primary within 10 min of the stop; the `pgfallback` checks below. |
| `pgfallback-replica-node-loss` | A replica's node stops with `docker stop -t 0` and starts again 120 s later. | The primary stays where it is; the `pgfallback` checks below. |
| `evidence` | `desired.sh`, `evidence.sh` with the `client-ca` Secret's certificate as `--ca`, and `prove.sh` as root on every node, through `/proc/<pid>/root` of the node's container. | `evidence.sh` finds no violation; on every node each `prove.sh` attempt has the value of the desired document; `cnpg_compliance_violations` is 0 for each of its 4 checks on every instance, read through `kubectl port-forward`. |

## pgfallback from outside the cluster

The `pgfallback-*` scenarios use the [`pgfallback`](pgfallback.md) package as an application outside the cluster does, from the runner against the node addresses. `live/pgfallback.sh` copies the program in `live/pgfallback/` out of the checkout and builds it there with `go get github.com/djosh34/cnpg-evidence/pgfallback@<commit>`, the checked out commit, through the Go module proxy, and checks that the version it got is of that commit. The summary names the version. In the repository the module points at the checkout instead, so the `live-client` job of `ci.yml` can vet, test and build it.

The program logs in as `orders` with the client certificate and `sslmode=verify-full`. Its connection string lists the three nodes by name on the rw port 5432, and `pgfallback` adds them on the read port 5433. pgx's `LookupFunc` maps the names to the node addresses; `live/values.yaml` adds the names to the server certificate. At the same time it runs:

- a `pgxpool.Pool` from `pgfallback.Pool`, and GORM on a `*sql.DB` with the options of `pgfallback.Stdlib`, each with a new query every 0.25 s and a write into `pgfallback_writes` every second;
- a connect to each rw address alone every 0.25 s, so the summary knows when rw took connections again.

Each query, write and connect starts on time, also while earlier ones still wait.

It logs every query, write and connect with its start and end, the address that served it and any error. Once every instance is ready and streaming and every read port answers, it runs 30 s more. The summary gives, in seconds after the event:

- when rw took no connection, and when each rw address alone took none: from the start of a connect that failed to the end of the next one that worked;
- for pgx and GORM, when queries and when writes failed and worked again, and when the attempt at rw that brought each back started and worked;
- the last query or write a read address served once rw was back;
- every failed query and write with its error.

The scenario fails when a read address served a query or write that started more than 1 s after rw was back, while rw took connections until 0.25 s after it ended (the connects alone see rw down up to 0.25 s late), and after pgfallback's own attempt at rw had worked, when that attempt worked only more than 1 s plus `connect_timeout` per rw address and one more after rw was back, when the last query or write of pgx or GORM did not work on rw, or when a write the program got acknowledged is not on the primary. The attempt is the first of that client that worked since rw went down and before it went down again; without one, 1 s alone counts. The bound allows for the attempt that was running when rw came back, which can still wait on the address that came back and those after it, and the next one, which waits on those before it and connects. The program sees the attempts because pgfallback runs them with the config's `LookupFunc` and `AfterConnect`, but not with the application's context, which the program marks. Every query and write is one statement, so none runs in a transaction that was already open.

## Run in GitHub Actions

The `live` workflow runs only on demand. Its inputs are the scenarios, separated by spaces, or `all`, and whether the writer runs. Each run is named after them, for example `live: all, writer on`.

```bash
gh workflow run live.yml --ref <branch> -f scenarios=all -f writer=true
gh workflow run live.yml --ref <branch> -f scenarios="switchover primary-node-loss" -f writer=false
```

A run has one job per scenario, each on its own `ubuntu-24.04` runner with its own cluster, and a last job `live` that fails when a scenario failed or did not run. A failed scenario prints the cluster's state after its failure.

`release.yml` starts with `live/release-check.sh`: a release runs only from a tag whose commit has a successful `live` run of every scenario, with and without the writer. Runs of a few scenarios each count too, so a failed scenario can be rerun on its own.

## Run one locally

On a Linux host with docker, go, helm, kubectl, curl and jq, and room for the cluster (the `evidence` scenario also needs yq, openssl, psql, python3, setpriv and sudo): about 4 GB of memory and 10 GB of disk. The docker network `live`, its subnet and the container names must be free.

```bash
bash live/up.sh
WRITER=on bash live/scenarios/primary-node-loss.sh
KUBECONFIG=/tmp/live/kubeconfig kubectl get pods -A
```

Start a fresh cluster for each scenario: a scenario leaves the cluster in another state than `up.sh` does. To remove it:

```bash
docker rm -f k3s-1 k3s-2 k3s-3 s3 s3-refuse
docker volume rm k3s-1 k3s-2 k3s-3 s3
docker network rm live
rm -rf /tmp/live
```

## Add a scenario

Add a script `live/scenarios/<name>.sh` that sources `live/lib.sh`, and the name to `live/scenarios.txt`. Most scenarios follow the shape of the existing ones: wait until `settled`, `start_monitoring` on a node the scenario does not stop, `expect_alert` for each alert that must fire and `allow_alert` for each that may, `start_client`, set `T0` and start the event, wait for what must happen with `wait_for`, then `wait_back`, `finish`, and the summary rows.
