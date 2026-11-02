# Live scenarios

The scripts in `live/` start the samples on a three-node k3s cluster in docker and run scenarios against it: nodes lost, a replica restart during a primary loss, a rollout, switchovers, a fence, a broken object store, a backup and restore, replicas that rejoin from the WAL the primary keeps or from the store, a replica that stops streaming, the evidence scripts. Each failure scenario checks that the cluster recovers by itself, that writes come back in time and that no acknowledged commit is lost, and writes its times to the job summary. The `live` workflow runs them on GitHub's runners, one job and one cluster per scenario.

## Files

| File | What it is |
|---|---|
| [`live/up.sh`](../live/up.sh) | Starts the cluster and installs the samples (see [The cluster](#the-cluster)) |
| [`live/node-init.sh`](../live/node-init.sh) | The first process of each node container: runs k3s and starts it again when it exits |
| [`live/values.yaml`](../live/values.yaml) | The chart values on top of `desired.yaml`: the S3 store's address |
| [`live/lib.sh`](../live/lib.sh) | Functions the scenarios share: bounded waits, the cluster's state, the client, the checks and the summary |
| [`live/client/`](../live/client) | The writer and the read probes, a small Go program (see [The writer and the read probes](#the-writer-and-the-read-probes)) |
| [`live/scenarios.txt`](../live/scenarios.txt) | The list of scenarios |
| [`live/scenarios/`](../live/scenarios) | One script per scenario |
| [`live/store.sh`](../live/store.sh) | The steps of `store-refuse` and `store-hang`, which differ only in how the store breaks |
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

It also builds `live/client`, installs `kubectl cnpg` 1.30.1 (pinned by checksum) into `$LIVE_WORK/bin`, and writes a client certificate for `orders-app.test`, which logs in as `orders`, into `$LIVE_WORK/certs`. `$LIVE_WORK` is `/tmp/live` by default and also holds a kubeconfig for each node's API server and the client's logs. The scripts use only those kubeconfigs, never the caller's `KUBECONFIG`.

Every wait in `live/` has a limit and fails with a message that says what it waited for.

## The writer and the read probes

`live/client` logs in like an application: as `orders` to the database `orders`, with the client certificate, `sslmode=verify-ca`, all three node addresses in the host list and a `connect_timeout` of 2 s.

- **The writer** keeps one pooled connection to the rw LoadBalancer on 5432 and inserts one row into `live_writes` every 0.25 s, each with its own number. Each attempt may take 5 s. It logs every acknowledged commit with the address of the instance that took it.
- **The read probes** open a new connection to the read port 5433 of each node once per second and log whether that node's instance answered.

A scenario runs the writer when `WRITER` is `on`, the default. With `WRITER=off` it writes nothing until the event is over, then makes one write through the rw LoadBalancer, which must succeed. The read probes run in both modes.

## Scenarios

Each scenario first waits until all three instances are ready and the primary streams to both replicas. Then, in both modes:

- Every instance must be ready and streaming again within 10 minutes of the event's end, and then every node's read port must answer within a minute.
- Every acknowledged commit, the final write included, must be in `live_writes` on the primary afterwards.
- The job summary gives, in seconds after the event, when each node's read port was down and back, and when every instance was ready and streaming.

With the writer, a scenario also fails when there was no acknowledged write for more than 180 s after the event started, and the summary gives the first write on a new primary and the longest time without a write. `rollout` allows only 30 s. `fence` and `one-node-left` stop writes on purpose, and `store-refuse` and `store-hang` may take up to 15 min, so they allow longer. The table says how long.

Without the writer, a former primary that rewound onto an idle new primary can wait for the primary's next WAL record (see [samples.md](samples.md#writes-reads-and-failover)). When not every instance is back after 10 minutes, the scenario makes its one write then, and every instance must be back within 10 s of it. The summary says so.

`quiet-rewind` always runs without the writer, also in a run with the writer on, since it tests a cluster with no writes.

| Scenario | Event | Checks |
|---|---|---|
| `primary-node-loss` | The primary's node stops with `docker stop -t 0` and starts again 120 s later. | Another instance becomes primary within 10 min of the stop; with the writer, it takes a write within 180 s of the stop. |
| `replica-node-loss` | A replica's node stops with `docker stop -t 0` for 6 min. | The primary stays where it is. |
| `switchover` | `kubectl cnpg promote` to a replica. | The replica becomes primary within 5 min; with the writer, it takes a write within 180 s. |
| `replica-restart-during-primary-loss` | The primary's node stops with `docker stop -t 0`; 10 s later, before any promotion, a replica's `postgres` container is killed on its node with `crictl stop --timeout 0`, and the kubelet starts it again. The node starts again 120 s after the stop. | The container runs again within 5 min; another instance becomes primary within 10 min of the stop; with the writer, it takes a write within 180 s of the stop. |
| `rollout` | `shared_buffers` changes on the `Cluster`, which needs a restart of every instance; once that is done, `kubectl cnpg promote` to a replica. | The rollout ends within 10 min with every instance on the new value, ready and streaming, and the primary on another instance; the replica becomes primary within 5 min. With the writer, writes stop for at most 30 s at any time; the summary gives the longest stop in each of the two. |
| `fence` | `kubectl cnpg fencing on` the primary, and `fencing off` 30 s later. | PostgreSQL on the primary stops within 2 min. Within 10 min of the unfence its `pg_ident` lines equal a replica's again and every instance is ready and streaming; the primary stays where it is. With the writer, writes may stop for those 30 s plus 10 min. The summary gives when the lines came back. |
| `quiet-rewind` | `kubectl cnpg promote` to a replica, with no writes. | The replica becomes primary within 5 min. If the former primary is not back within 10 min, the one write must bring it back within 10 s. |
| `one-node-left` | The primary's node and a replica's node stop with `docker stop -t 0` and start again 120 s later. | The last node's read port answers every probe while the two nodes are down. With the writer, no write is acknowledged then, writes may stop for those 120 s plus 180 s, and the primary takes a write within 180 s of the start. |
| `replica-down-long` | A replica's node stops with `docker stop -t 0`, and the primary writes at least 1.2 GB of WAL. 360 s after the stop the store starts refusing connections and the node starts. | The replica streams and has replayed the primary's WAL within 10 min of the start, with the store still refusing; then the store comes back. The summary gives how many MB behind the replica was when its pod turned ready, which opens its node's read port. |
| `store-refuse`, `store-hang` | Twice, the store breaks and the primary switches WAL twice, so WAL waits for the archive; then the event. First the primary's node stops with `docker stop -t 0` and starts again 120 s later; then `kubectl cnpg promote` to a replica. The store comes back 60 s after the node started, and in the switchover 60 s after the new primary took over. | After each event, within 15 min, another instance is primary with a standby streaming from it; with the writer, it takes a write. With the writer, writes stop for at most 15 min. The summary gives the times of both events. |
| `backup-restore` | `kubectl cnpg backup` to the store; the client stops 30 s after it completed, and the primary switches WAL and archives it. Then the chart restores a new cluster `pg-restore` from the store, as [samples.md](samples.md#restore-into-a-new-cluster) says. | The backup completes within 10 min. `pg-restore` has three ready instances with two streaming replicas within 15 min, every acknowledged commit, and `cnpg_compliance_violations` 0 for each of its 4 checks on every instance. |
| `rejoin-from-archive` | With `wal_keep_size` set to 64MB by `helm upgrade`: a replica's node stops, the primary writes 256 MB of WAL and makes checkpoints until the WAL file it wrote at the stop is gone from its `pg_wal`, and the node starts. Then the same with the primary's node: once another instance is primary, it writes 256 MB until its WAL file of the moment it took over is gone. | Both rejoin from the store: every instance is ready and streaming within 10 min of each start. With the writer, the new primary takes a write within 180 s. |
| `replica-not-streaming` | Prometheus with `samples/monitoring/rules.yaml` scrapes every instance, as [monitoring.md](monitoring.md#scrape-targets-and-labels) says, from the namespace `otel`. A firewall rule in a replica pod's network namespace rejects its connections to 5432, and the primary ends its WAL sender; its exporter keeps answering. The rule goes once the alert fires. | `CNPGReplicaDown` fires for the replica within 8 min while Prometheus still gets its metrics, and resolves within 2 min after the replica streams again. The summary lists the alerts that fired. |
| `evidence` | `desired.sh`, `evidence.sh` with the `client-ca` Secret's certificate as `--ca`, and `prove.sh` as root on every node, through `/proc/<pid>/root` of the node's container. | `evidence.sh` finds no violation; on every node each `prove.sh` attempt has the value of the desired document; `cnpg_compliance_violations` is 0 for each of its 4 checks on every instance, read through `kubectl port-forward`. |

## Run in GitHub Actions

The `live` workflow runs only on demand. Its inputs are the scenarios, separated by spaces, or `all`, and whether the writer runs. Each run is named after them, for example `live: all, writer on`.

```bash
gh workflow run live.yml --ref <branch> -f scenarios=all -f writer=true
gh workflow run live.yml --ref <branch> -f scenarios="switchover primary-node-loss" -f writer=false
```

A run has one job per scenario, each on its own `ubuntu-24.04` runner with its own cluster, and a last job `live` that fails when a scenario failed or did not run. A failed scenario prints the cluster's state after its failure.

`release.yml` starts with `live/release-check.sh`: a release runs only from a tag whose commit has a successful `live` run of every scenario, with and without the writer. Runs of a few scenarios each count too, so a failed scenario can be rerun on its own.

## Run one locally

On a Linux host with docker, go, helm, kubectl and curl, and room for the cluster (`replica-not-streaming` also needs jq, and the `evidence` scenario yq, jq, openssl, psql, python3, setpriv and sudo): about 4 GB of memory and 10 GB of disk. The docker network `live`, its subnet and the container names must be free.

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

Add a script `live/scenarios/<name>.sh` that sources `live/lib.sh`, and the name to `live/scenarios.txt`. Most scenarios follow the shape of the existing ones: wait until `settled`, `start_client`, set `T0` and start the event, wait for what must happen with `wait_for`, then `wait_back`, `finish`, and the summary rows.
