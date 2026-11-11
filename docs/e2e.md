# Scenarios

A scenario is a short Gherkin text in [`samples/features/`](../samples/features) about what happens to the cluster and what must hold after it, such as a lost node, a switchover or a broken store. Each run builds a new three-node k3s cluster from [`samples/`](../samples), plays one scenario on it, then plays [`always.feature`](../samples/features/always.feature).

```gherkin
@primary-node-loss
Scenario: The primary's node is lost for 2 minutes
  When the primary's node is killed
  Then another instance is primary < 600 s
  When 120 s pass after the kill
  And the node starts
```

## Run a scenario

```bash
./e2e.sh                 # lists the scenarios, exits 2
./e2e.sh switchover      # runs one
```

The host needs docker, bash, Go 1.27 and the [inotify limit](#raise-the-inotify-limit). `./e2e.sh` runs `TestScenario` in [`e2e/scenario_test.go`](../e2e/scenario_test.go) with `go test`, so you can run it directly too:

```bash
go -C e2e test -run '^TestScenario$' -count=1 -timeout 90m -v . -scenario switchover
```

Without `-scenario` the test skips, so `go test ./...` in `e2e/` starts no container.

The test builds [`e2e/Dockerfile`](../e2e/Dockerfile) for the host's own architecture and keeps it as `cnpg-evidence-e2e:local`, so the next run reuses its layers. It copies `samples/` into the container, runs it privileged and copies `/results` out to `results/` at the end. testcontainers removes the container and its volumes when the test ends. If the test process is killed, its Ryuk container removes them. A run never writes into `samples/`.

Exit codes: 0 the scenario passed, 1 it failed, 2 it could not run. One run takes 15 to 40 minutes.

## Raise the inotify limit

Each k3s node takes many inotify instances, and `fs.inotify.max_user_instances` is the host's limit for every container. A run needs 1024 and stops with a message when the limit is lower. It never changes the limit itself.

```bash
bash e2e/inotify.sh
```

The script raises the limit to 1024 with `sudo sysctl` until the next reboot. To keep it, put `fs.inotify.max_user_instances = 1024` into a file in `/etc/sysctl.d/`. GitHub's Ubuntu runners already have enough.

## Read the results

Each run writes a new directory `results/<scenario>-<time>/`, time in UTC:

| File | What |
|---|---|
| `timing.md` | One row per line of the scenario and of `always.feature`: its result, how long it took, the time since the event it refers to, and what it measured. It is printed at the end of the log too. |
| `cucumber.json`, `junit.xml` | The scenario's steps and results. |
| `always.cucumber.json`, `always.junit.xml` | The same for `always.feature`. |
| `state.txt` | `docker ps`, the last log lines of every container, the nodes, pods, events and CNPG objects, and the alert history. After a failure it is also printed at the end of the log. |
| `client.log` | The client's log: one line per read, write, connect and attempt, with the address it used ([format](../e2e/client/main.go)). |
| `pgfallback.md` | The [pgfallback report](#the-pgfallback-report), for scenarios with a `pgfallback has been healthy` line. |
| `evidence.json`, `evidence.desired.json`, `prove.<node>.json`, `prove.desired.json`, `host-check.<node>.json` | What the evidence scripts printed, for scenarios that run them. `cnpg-report` [draws them](report.md#run). |

Start with `timing.md`: the first row with a failure names the line that failed, and its *Measured* column gives what was seen. Then read `state.txt` for what the cluster looked like at the end.

## Run scenarios in CI

On GitHub, [`e2e.yml`](../.github/workflows/e2e.yml) runs every scenario on an amd64 and an arm64 runner, 46 jobs in parallel. It runs on demand only:

```bash
gh workflow run e2e.yml --ref <branch>
gh run list --workflow e2e.yml --limit 1          # the run's id
gh run download <run id> --name switchover-X64    # one job's results
```

Each job uploads its `results/` as `<scenario>-<arch>`, where the arch is `X64` or `ARM64`, also when the scenario failed.

In any other CI, run one job per scenario with a matrix variable and this one line:

```bash
./e2e.sh "$SCENARIO"
```

The job needs docker that can run privileged containers, Go 1.27 and the inotify limit. Keep `results/` as the job's artifact. An unset or empty `$SCENARIO` exits 2, so the job fails rather than pass without running anything.

## What a run does

What runs outside k3s in production runs as a container next to the k3s nodes, never as a pod. Everything below runs in the inner docker of the one e2e container:

| Inside k3s | Outside k3s, as containers |
|---|---|
| k3s: CoreDNS, Traefik, local-path, metrics-server | `dns`: CoreDNS for every name below |
| cert-manager, with a ClusterIssuer of the company CA | `acme.example.test`: OpenBao as the company CA, serving ACME |
| The CNPG operator and the barman-cloud plugin | `s3.example.test`: versitygw as the S3 store, with TLS |
| The CNPG cluster `pg` | `otel`, `prometheus`, `alertmanager`, `grafana` `.example.test`: the [monitoring](monitoring.md) |
| The OTel collectors | `orders-app.test`: the client, reading and writing through [pgfallback](pgfallback.md) |

1. Checks the inotify limit and starts its own dockerd.
2. Builds the `client` image, then creates the outside containers, copies their files in with `docker cp`, and starts them. The company CA gets a new root on every run.
3. Starts three k3s servers with embedded etcd, `k3s-1.example.test` to `k3s-3.example.test`, with [`samples/k3s/`](../samples/k3s). Each node runs [`e2e/node-init.sh`](../e2e/node-init.sh), which restarts k3s when it exits, so the pods outlive k3s as they do under systemd.
4. Runs one CoreDNS, metrics-server and Traefik pod per node, as [samples.md](samples.md#one-pod-per-node) says.
5. Makes the Secrets only the run knows, then installs the releases of [`samples/charts/releases.yaml`](../samples/charts/releases.yaml) in order.
6. Waits until the cluster is healthy, takes a first backup, and waits until Prometheus has every source's metrics. It then names the instances: the primary, replica 1 and replica 2.
7. Runs the scenario. Its first When line starts the client.
8. Runs `always.feature`, also after a failed scenario, and writes the results.

The client gets its own certificate from the company CA by ACME. For the whole scenario it reads and writes through `pgfallback` every 0.25 s, each with a 10 s limit, and connects to each node's rw port alone every 0.25 s. `Given no writes` starts it without writes.

## Add or change a scenario

1. Write the scenario in a `.feature` file of `samples/features/`, with its own tag: lower-case words with dashes. Use only the lines of the [vocabulary](#vocabulary).
2. Add the tag to the `scenario` list of [`e2e.yml`](../.github/workflows/e2e.yml).
3. Check both without a cluster: `go -C e2e test ./...`. `TestFeaturesUseTheVocabulary` fails on a line outside the vocabulary, on a tag used twice, and when the list in `e2e.yml` differs from the tags.
4. Run it: `./e2e.sh <tag>`, or the [workflow](#run-scenarios-in-ci) for both architectures.

A new kind of line needs a word in [`e2e/vocab.go`](../e2e/vocab.go) and a function that does or checks it. Step code only turns a line into one call.

### Line shapes

| Shape | Meaning |
|---|---|
| `<thing> is <word>` | An event: does it. A state: checks it now. A measure: checks it over the whole scenario. |
| `<thing> is <word> < N s` | A state: waits up to N s from the line above. A measure: its limit. |
| `<thing> is <word> < N s after the <event>` | A state: waits until N s after that event. |
| `<thing> is <word> for N s` | A state: checks it for the next N s. |
| `<thing> has been <word> since the <event>` | Checks the whole time from that event to now. |
| `<thing> starts`, `stops`, `runs`, `passes` | The same lookup as `is`. |
| `N s pass`, `N s pass after the <event>` | Waits. |
| `<ALERT> fires`, `resolves for <role> < N s` | Waits up to N s until the alert fires, or no longer fires. Without a limit, checks now. |
| `<ALERT> fired`, `has not fired`, `may fire for <role>` | Whether it fired since the scenario started; `may fire` allows it. |
| `Alertmanager gets <ALERT> for <role>` | Sends Alertmanager the critical alert for 2 min, as the rule evaluator would. An event. |
| `Alertmanager sends`, `mutes <ALERT> for <role> < N s` | Waits until a notification of it reached the receiver, or Alertmanager holds it muted. |
| `no writes` | The client does not write in this scenario. |
| `host-check.sh fails exactly these checks on every node:` | With a table of `check` and `value`: the checks that fail on every node, and no other. |

`is` may be `are`, and `has` may be `have`. An event comes only in a Given or When line, a check only in a Given or Then line. The event names an `after the` or `since the` line can use are the words in quotes below. An event's time is when the run finished doing it.

**Roles:** `the primary`, `replica 1` and `replica 2`, named when the cluster is ready; `the new primary`, the instance that became primary last; `another instance`, any instance but the primary; `a replica`, an instance other than the one that became primary last. An alert line names a role or `the cluster`.

### Vocabulary

Events:

| Line | Does |
|---|---|
| `<role> is promoted` | `kubectl cnpg promote`. "promote" |
| `<role>'s node is drained` | `kubectl drain` of the instance's node, which goes on while the scenario does. "drain" |
| `the node is uncordoned` | `kubectl uncordon` once the drain is done. "uncordon" |
| `<role>'s node is killed`, `<role>'s node and <role>'s node are killed` | `docker stop -t 0` of the nodes, as lost VMs. The run then uses a running node's API server. "kill" |
| `the node starts`, `the nodes start` | `docker start` of the killed nodes. "start" |
| `<role>'s postgres container is killed` | `crictl stop --timeout 0` of PostgreSQL's container, as a crash; the kubelet starts it again. |
| `<role> is fenced`, `<role> is unfenced` | `kubectl cnpg fencing on` and `off`. "fence", "unfence" |
| `the instance image is changed` | `helm upgrade` of `pg` with `values/new-image.yaml`. "change" |
| `wal_keep_size is set to <n>MB` | `helm upgrade` of `pg` with that `cluster.walKeepSize`. "change" |
| `<n> MB of WAL is written on <role>` | Writes rows on the instance until it has written that much WAL. |
| `<role>'s WAL is switched` | `pg_switch_wal()`. |
| `the store is stopped`, `the store is paused` | Stopped, the store refuses connections. Paused, `docker pause`: it accepts connections and never answers. |
| `the store starts` | The store is back. |
| `a backup is taken` | `kubectl cnpg backup` through the plugin. "backup" |
| `pg-restore is restored from the store` | Installs the cluster's chart as `pg-restore`, restored from the backups, as [samples.md](samples.md#restore-into-a-new-cluster) says. "restore" |
| `the catalog is read on <role>` | `select count(*)` of every catalog table of every database. |
| `a row is written` | One insert on the primary, outside the client. |
| `a <n> s statement is committed on <role>` | One transaction runs `pg_sleep(<n>)`, inserts a row and commits. |
| `a commit is started on <role>` | One insert that goes on while the scenario does. |
| `replay on <role> is paused`, `is resumed`, and `on <role> and <role> are` | `pg_wal_replay_pause()` or `pg_wal_replay_resume()`. |
| `<role> is cut off`, `<role> is reconnected` | A firewall rule in the pod's network namespace rejects its connections to 5432, and the primary ends its WAL sender; then the rule goes. |
| `writing stops` | The client stops writing; reads go on. The line ends once every write it started has ended. |
| `desired.sh runs`, `evidence.sh runs`, `prove.sh runs`, `host-check.sh runs` | Runs the script as its doc says: `desired.sh` and `evidence.sh` against the cluster, `prove.sh` and `host-check.sh` as root on every node. |

States, checked now, within the line's limit, or for its time:

| Line | Holds when |
|---|---|
| `the cluster is healthy` | Three ready instances, phase healthy, two replicas streaming from the primary. |
| `pg-restore is healthy` | The same for `pg-restore`. |
| `<role> is primary`, `<role> is still primary` | The instance is the current primary, out of recovery. |
| `no instance is promoted` | The target primary is still the primary. |
| `the drain is done` | The `kubectl drain` ended and succeeded. |
| `<role> is down` | PostgreSQL on the instance takes no connection. |
| `<role>'s postgres container is running` | It runs again after the kill. |
| `<role> is caught up` | The pod is ready, and the instance streams and has replayed the primary's WAL up to where it was a moment before. |
| `<role> is not streaming` | Not in the primary's `pg_stat_replication`. |
| `<role> is idle after a WAL switch` | No WAL since a switch, for 30 s. |
| `the chart's pg_ident lines are on <role>`, `on every instance` | The pg_ident lines every instance had at the first such line are there. |
| `every instance is on the new image` | Every postgres container runs the image of `values/new-image.yaml` and is ready. |
| `wal_keep_size is <n>MB on every instance` | `show wal_keep_size` gives it. |
| `<role>'s WAL is archived` | The file it switched away from is archived. |
| `<role>'s WAL is waiting for the store` | It has WAL files marked `.ready`. |
| `the WAL <role> needs is gone from <role>` | After two checkpoints, the WAL file the first instance needs is gone from the second's `pg_wal`. |
| `the backup is done` | The backup's phase is completed. |
| `the commit is done` | The started insert ended and succeeded. |
| `<role>'s metrics are arriving` | Prometheus has its `cnpg_collector_up` 1 from the last 30 s. |
| `the replica lag is healthy for N s` | Each replica's `cnpg_replica_lag_seconds` stays under 1 s. |
| `compliance is healthy`, `compliance on pg-restore is healthy` | Every instance reported the four compliance checks as 0 in the last 30 s. |
| `the exporters are healthy` | Every exporter answered in the last 30 s with its query metrics. |
| `evidence.sh passes`, `prove.sh passes` | No violation; every probe as in the desired document, on every node. |
| `no acknowledged write is lost`, `... lost in pg-restore` | Stops the client; every write it got acknowledged is in `e2e_writes` on the primary, or of `pg-restore`. |
| `the alerts are healthy` | No alert fires. The alerts the scenario says `fired` or `fires` fired, and no other did but those it says `may fire`. |
| `the dashboard is healthy` | Every panel of the dashboard gives a value through Grafana. |

Measures and since lines:

| Line | Holds when |
|---|---|
| `reading is healthy < N s` | The client never went N s without a successful read. |
| `writing is healthy < N s` | The client never went N s without an acknowledged write, until the writes stop. A scenario's own limit also replaces the one in `always.feature`. With `after the <event>`: an acknowledged write sent after the event, by N s after it. |
| `writing has been down since the <event>` | No write sent since the event was acknowledged. |
| `the exporters of <role> and <role> have been healthy since the <event>` | In every 15 s one of their exporters answered with its query metrics, and none went 60 s without answering. |
| `pgfallback has been healthy since the <event>` | The [pgfallback report](#the-pgfallback-report) finds nothing `pgfallback` must not do. |

### The pgfallback report

[`e2e/fallback.go`](../e2e/fallback.go) reads `client.log` from the event on and writes `pgfallback.md`: when rw took no connection, when reads and writes failed and worked again, and every failed read and write. The line fails when a read address served a read or write that started more than 1 s after rw was back and after the pool's own attempt at rw had worked; when that attempt worked more than 1 s plus `connect_timeout` per rw address and one more after rw was back; or when the log's last read or write did not work on rw.
