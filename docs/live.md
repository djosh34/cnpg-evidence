# Live scenarios

The scripts in `live/` start the samples on a three-node k3s cluster in docker and run scenarios against it: a node lost, a switchover, the evidence scripts. Each failure scenario checks that the cluster recovers by itself, that writes come back in time and that no acknowledged commit is lost, and writes its times to the job summary. The `live` workflow runs them on GitHub's runners, one job and one cluster per scenario.

## Files

| File | What it is |
|---|---|
| [`live/up.sh`](../live/up.sh) | Starts the cluster and installs the samples (see [The cluster](#the-cluster)) |
| [`live/values.yaml`](../live/values.yaml) | The chart values on top of `desired.yaml`: the S3 store's address |
| [`live/lib.sh`](../live/lib.sh) | Functions the scenarios share: bounded waits, the cluster's state, the client, the checks and the summary |
| [`live/client/`](../live/client) | The writer and the read probes, a small Go program (see [The writer and the read probes](#the-writer-and-the-read-probes)) |
| [`live/scenarios.txt`](../live/scenarios.txt) | The list of scenarios |
| [`live/scenarios/`](../live/scenarios) | One script per scenario |
| [`live/plan.sh`](../live/plan.sh) | Turns the workflow's `scenarios` input into the list of jobs |
| [`live/after-failure.sh`](../live/after-failure.sh) | Prints the cluster's state after a failed scenario |
| [`live/host-check.sh`](../live/host-check.sh) | Runs `host-check.sh` on one k3s node in docker and checks that only the known failures of a container node fail; the `ci` workflow runs it (see [host-check.md](host-check.md#known-failures-on-container-nodes)) |
| [`live/release-check.sh`](../live/release-check.sh) | The first job of `release.yml`: fails unless the tag's commit passed every scenario, with and without the writer |
| [`.github/workflows/live.yml`](../.github/workflows/live.yml) | The `live` workflow |

## The cluster

`live/up.sh` takes about 8 minutes on a runner. It starts:

- Three k3s servers with embedded etcd, as the docker containers `k3s-1` to `k3s-3` on the docker network `live` (`10.77.0.0/24`, nodes at `.11` to `.13`). The k3s image is pinned by digest.
- An S3 store, versitygw in the container `s3` at `10.77.0.20`, with the bucket `example-bucket`. Inside the cluster it is `s3.s3.svc:9000`.
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

With the writer, a scenario also fails when there was no acknowledged write for more than 180 s after the event started, and the summary gives the first write on a new primary and the longest time without a write.

Without the writer, a former primary that rewound onto an idle new primary can wait for the primary's next WAL record (see [samples.md](samples.md#writes-reads-and-failover)). When not every instance is back after 10 minutes, the scenario makes its one write then, and every instance must be back within 10 s of it. The summary says so.

| Scenario | Event | Checks |
|---|---|---|
| `primary-node-loss` | The primary's node stops with `docker stop -t 0` and starts again 120 s later. | Another instance becomes primary within 10 min of the stop; with the writer, it takes a write within 180 s of the stop. |
| `replica-node-loss` | A replica's node stops with `docker stop -t 0` for 6 min. | The primary stays where it is. |
| `switchover` | `kubectl cnpg promote` to a replica. | The replica becomes primary within 5 min; with the writer, it takes a write within 180 s. |
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

On a Linux host with docker, go, helm, kubectl and curl, and room for the cluster (the `evidence` scenario also needs yq, jq, openssl, psql, python3, setpriv and sudo): about 4 GB of memory and 10 GB of disk. The docker network `live`, its subnet and the container names must be free.

```bash
bash live/up.sh
WRITER=on bash live/scenarios/primary-node-loss.sh
KUBECONFIG=/tmp/live/kubeconfig kubectl get pods -A
```

Start a fresh cluster for each scenario: a scenario leaves the cluster in another state than `up.sh` does. To remove it:

```bash
docker rm -f k3s-1 k3s-2 k3s-3 s3
docker volume rm k3s-1 k3s-2 k3s-3 s3
docker network rm live
rm -rf /tmp/live
```

## Add a scenario

Add a script `live/scenarios/<name>.sh` that sources `live/lib.sh`, and the name to `live/scenarios.txt`. Most scenarios follow the shape of the existing ones: wait until `settled`, `start_client`, set `T0` and start the event, wait for what must happen with `wait_for`, then `wait_back`, `finish`, and the summary rows.
