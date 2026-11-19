# Scenarios

A scenario is a short Gherkin text in [`samples/features/`](../samples/features) about what happens to the cluster and what must hold after it, such as a lost node, a switchover or a broken store. Each run builds a new three-node k3s cluster from [`samples/`](../samples), or from a [variant](#run-a-variant), with every version from one [manifest](#the-version-manifest), plays one scenario on it, then plays [`always.feature`](../samples/features/always.feature).

```gherkin
@primary-node-loss
Scenario: The primary's node is lost for 2 minutes
  When the primary's node is killed
  Then another instance is primary < 600 s
  When 120 s pass after the kill
  And the node starts
```

Eight scenarios run the evidence scripts, one part each, so a gap in one part never hides another: `evidence-client-ca`, `evidence-logins`, `evidence-postgres`, `evidence-pods`, `evidence-tls` and `evidence-kubernetes` run one [part of `evidence.sh`](evidence.md#one-part), `prove` runs [`prove.sh`](prove.md) on every node, and `compliance` checks that every instance reports the compliance checks as passing.

Ten scenarios, in [`alerts.feature`](../samples/features/alerts.feature), are one per alert of the [monitoring](monitoring.md#alerts), each named after its alert: each causes the alert's condition for real, checks that the alert fires with its labels and that Alertmanager sends it, ends the condition, and checks that the alert resolves and that Alertmanager sends it resolved.

`ca-rotation`, in [`k3s.feature`](../samples/features/k3s.feature), rotates the k3s CAs, etcd's included, while the client writes and reads, as [docs.k3s.io](https://docs.k3s.io/cli/certificate#rotating-self-signed-ca-certificates) says for the CAs k3s made itself. k3s's own `rotate-default-ca-certs.sh`, of the k3s version the nodes run, makes new server, client, request-header, etcd server and etcd peer CAs, each cross-signed by the old one, and `k3s certificate rotate-ca` stores them in etcd. As [certificates.md](go-live/certificates.md#a-new-serving-certificate-on-every-server-after-a-ca-rotation) says, every other server then gets the marker that makes k3s sign its serving certificate again. k3s then restarts on one node after another. After each restart the scenario checks that the node serves and uses certificates of the new CAs alone, and that etcd has three healthy members; at the end, that every node is Ready and the cluster is healthy. The test does nothing for the cluster in between.

Two scenarios run [`host-check.sh`](host-check.md#in-the-scenarios) on every node. `host-check-docker` expects the three checks a node in a container can never pass to fail, each with its known value, so a change to them shows. `host-check` expects every other check to pass, in the samples and in a variant: those checks depend on the settings, so a failure there is a real gap.

## Run a scenario

```bash
./e2e.sh                                    # lists the scenarios, exits 2
./e2e.sh switchover                         # runs one on the samples
./e2e.sh switchover my-variant              # runs one on variants/my-variant
./e2e.sh switchover my-variant v1.34.yaml   # with the versions of versions/v1.34.yaml
./e2e.sh switchover '' v1.34.yaml           # the samples with those versions
```

The host needs what the [README](../README.md#run-a-scenario) lists. `./e2e.sh` runs `TestScenario` in [`e2e/scenario_test.go`](../e2e/scenario_test.go) with `go test`, so you can run it directly too:

```bash
go -C e2e test -run '^TestScenario$' -count=1 -timeout 90m -v . -scenario switchover -variant my-variant -manifest v1.34.yaml
```

Without `-variant`, or with it empty, the run uses the samples. Without `-manifest`, or with it empty, it uses `versions/latest.yaml`.

Without `-scenario` the test skips, so `go test ./...` in `e2e/` starts no container.

The test builds [`e2e/Dockerfile`](../e2e/Dockerfile) for the host's own architecture, with kubectl, kubectl-cnpg and k3s's CA rotation script of the manifest, and keeps it as `cnpg-evidence-e2e:local`, so the next run reuses its layers. It copies `samples/` into the container, or `samples/features/` and the variant's directory, and the manifest file to `/manifest.yaml`. It runs the container privileged and copies `/results` out to `results/` at the end. testcontainers removes the container and its volumes when the test ends. If the test process is killed, its Ryuk container removes them. A run never writes into `samples/` or `variants/`.

`./e2e.sh` exits 0 when the scenario passed, 2 without a scenario, and 1 otherwise. The log gives the container's own code: 1 when the scenario failed, 2 when it could not run or could not keep its files. One run takes 15 to 40 minutes.

## Run a variant

A variant is another set of settings for the same scenarios: a directory `variants/<name>/`, its name lower-case words with dashes. It is complete and shaped like `samples/`, so it can be compared file by file with another cluster's charts:

| Path | What |
|---|---|
| `charts/releases.yaml` | The releases the run installs, in order, as in [`samples/charts/releases.yaml`](../samples/charts/releases.yaml). |
| `charts/<chart>/` | Every chart a release names, the variant's own copy. A chart that wraps an upstream chart names it as a dependency without a version; the run takes the version from the manifest. |
| `values/<release>.yaml` | The run's values of a release, put on top of the values `releases.yaml` names. |
| `desired.yaml` | The cluster's values, which the evidence scripts read. |
| `k3s/config.yaml`, `k3s/manifests/` | Each node's k3s config, and the manifests k3s applies. |
| `k3s/patches.yaml` | Changes to objects of k3s's own manifests, such as 3 CoreDNS replicas: each a `kubectl patch --type=merge` the run applies once k3s runs. |
| `gaps.md` | The scenarios the variant fails on purpose, [below](#a-variants-gaps). |
| `monitoring/` | `rules.yaml`, `alertmanager.yaml` and `dashboard.json`, which the run's monitoring loads. |

The scenarios are always those of `samples/features/`; a variant has no `features/`. A run refuses a variant with a symlink, as it would not copy it. The release of the cluster is `pg`, its cluster `pg` in the namespace `databases`.

A variant run differs from a samples run in three ways:

- The client reads and writes through GORM, whose `database/sql` pool uses the pgx driver, with no pgfallback and no read port. Its connection string lists the rw port of the three nodes with `target_session_attrs=read-write` and `connect_timeout=2`.
- Its reads stop while the primary changes or stops, as its writes do. So in a scenario that promotes an instance, fences the primary, kills or drains the primary's node, or rolls out a new image, reading in `always.feature` takes the limit of writing: the scenario's own, or 180 s. In every other scenario it keeps 5 s, as in the samples: a replica that does not confirm blocks commits, not reads.
- It leaves out `pgfallback-drain`, `pgfallback-primary-node-loss` and `pgfallback-replica-node-loss`, which test pgfallback, and `rejoin-from-archive`. That scenario needs the primary to drop WAL a stopped replica needs, which CNPG's replication slots prevent when they are on, as CNPG has them by default. Every scenario with a lost node or a switchover still checks that the instances rejoin, through `always.feature`. `./e2e.sh <scenario> <variant>` exits 1 for these before it builds anything.

What the run adds to a variant's settings is only what a run alone knows:

- **The CA root:** the company CA gets a new root on every run, in the Secrets below and in the client.
- **The run Secrets**, made before the charts: `company-acme-eab` (the EAB key of the samples' ClusterIssuer) and `company-ca` in `cert-manager`; `client-ca`, `s3-ca`, `company-ca` and `backup-creds` (CNPG's keys of the [store](#the-store)) in `databases`; `company-ca` in `otel`. For a variant with one Issuer per Certificate, also an EAB key per Issuer, since a key is good for one ACME account: `pg-server-acme-eab`, `pg-replication-acme-eab`, `pg-restore-server-acme-eab` and `pg-restore-replication-acme-eab` in `databases`, and `otel-client-acme-eab` in `otel`. An EAB Secret has `keyID` and `secret`.
- **The test endpoints:** the containers outside k3s, by the names in [What a run does](#what-a-run-does). A variant's values name them as the samples do: `https://acme.example.test/v1/pki/acme/directory` and `https://s3.example.test` in [`samples/values/`](../samples/values), `otel.example.test:4317` in the collector's chart, the node names `k3s-1.example.test` to `k3s-3.example.test`, and the client `orders-app.test` in `desired.yaml`.
- **The nodes:** each node's `--node-ip`, `--tls-san`, `--resolv-conf` and join address.
- **The nodes' data filesystems**, one per node, as in [Each node's data filesystem](#each-nodes-data-filesystem).

[`variants/first-list`](../variants/first-list) applies the [base and the first list](go-live/README.md) of `docs/go-live/`, and leaves every other setting at the CNPG, chart or k3s default. It keeps four settings of the samples, also named in the [go-live README](go-live/README.md): the samples' image with its uid and gid 999, since the list's uid item needs an image whose `postgres` is not CNPG's uid 26; `storageSize: 50Gi`, since CNPG has no default size; a bootstrap with no `app` database, in place of the import the scenarios cannot do; and `conntrack-max-per-core=0` for kube-proxy, which cannot set `nf_conntrack_max` in a node in docker. As for the samples, the run's first backup stands in for a schedule.

[`variants/every-item`](../variants/every-item) is `first-list` plus every item of [later.md](go-live/later.md): metrics over TLS, no NodePorts on the rw LoadBalancer, the queries in a Secret, the operator's and the plugin's RBAC cut to their namespaces, cert-manager, Traefik and metrics-server on every node, the plugin's `WATCH_NAMESPACE`, and an API audit log. The audit log stays on the node; the state dump shows its newest lines.

### A variant's gaps

A variant that lacks a setting of the samples fails the scenarios that show what it lacks, and that is the point of running it. Its `gaps.md` lists them: one row per scenario expected to fail, with the line that fails, the gap, and the go-live item that closes it. See [first-list's](../variants/first-list/gaps.md) and [every-item's](../variants/every-item/gaps.md).

A run of the variant is right when its red scenarios are exactly those rows, each failed on the line its row names. A red scenario not in the list, and a listed scenario that passes, are both defects. For the first, read its failed line: a gap the variant really has gets its row; any other cause, such as a test bug or a timing, is fixed in the test. A variant's settings never change just to make a run pass. For the second, the row goes only once evidence shows the gap is closed. In CI the [verdict job](#run-scenarios-in-ci) checks this for the scenarios a run picked; `e2e/cmd/verdict` reads the first `` `quoted` `` text of each row's second column as its failed line.

On GitHub, give the variant as the workflow's input:

```bash
gh workflow run e2e.yml --ref <branch> -f variant=my-variant
```

The run's name says which settings it used, and its matrix leaves out the four scenarios above.

## The version manifest

Every version of the system under test that a run uses is in one file of [`versions/`](../versions): k3s, its airgap images, the upstream charts, every image they run, the PostgreSQL images, kubectl, kubectl-cnpg and k3s's CA rotation script. There is one manifest for the latest k3s patch of each minor version, `v1.33.yaml` to `v1.37.yaml`, and `latest.yaml`, a symlink to the newest of them. The samples and every variant run with `versions/latest.yaml` unless a run names another. The containers outside k3s, such as the store and the monitoring, and the images and tools that build the e2e image, keep their own pins in `e2e/`.

| Key | What a run does with it |
|---|---|
| `k3s` | The node image by tag and digest; the airgap tarball and its sha256 for amd64 and arm64, which each node imports; `images`, the release's `k3s-images.txt`. |
| `tools` | The versions and sha256 of kubectl, of the k3s release's Kubernetes version, and kubectl-cnpg, of the operator's version, for amd64 and arm64, and the URL and sha256 of k3s's `rotate-default-ca-certs.sh`. `TestScenario` gives them to `e2e/Dockerfile` as build arguments. |
| `charts` | The repository and version of each upstream chart. The run writes them into the dependencies of its copy of each wrapper chart. |
| `postgresql` | `imageName`, the instance image every cluster runs, which the `cnpg-cluster` charts read. `rolloutFrom`, the image the `rollout` scenario starts on before it changes to `imageName`. |
| `cert-manager`, `cloudnative-pg`, `plugin-barman-cloud`, `agent`, `cluster` | The images of each upstream chart, under the name its wrapper chart gives it as a dependency, in the chart's own values: its default image and tag, pinned by digest. A chart without a digest field gets the digest in its tag. The two collectors run the collector's Kubernetes distribution, `otelcol-k8s`. |

Every release gets the manifest with `--values`, before its own values files, so each chart finds its keys and ignores the others. A manifest loads only when each of these chart image blocks has a `repository` and its digest where its chart reads it: in `tag` for `cloudnative-pg` and `plugin-barman-cloud`, in `digest` for the others. A chart without its block would run its own default image by tag. Any other image block must have a digest too, and no block may have one in both `digest` and `tag`, since its chart reads only one. No upstream chart is copied into `samples/` or `variants/`, and none is changed: their images come only through these values.

Once the cluster is up, and again at the end of `always.feature`, the run lists the images on every node with `crictl images`. An image the manifest pins anywhere, as `<name>@sha256:…` or as a chart's `repository` with a `digest` or a digest in its `tag`, passes by repository and digest. An image of `k3s.images` passes by repository and tag, and only when k3s imported it: k3s labels each image it imports from the airgap tarball with `io.cattle.k3s.pinned`, which `ctr images ls` shows, and never one containerd pulls. As an import after a pull of the same tag would carry that label too, the check also fails when a node's `containerd.log` shows a pull of an image of `k3s.images`, and when k3s rotated that log, which then no longer shows every pull. Any other image fails the run, by name. The check sees what is on the nodes at those two times, not how each image was asked for.

The run copies only the one manifest file it uses, so it follows the symlink `latest.yaml`.

### Make a manifest

`e2e/cmd/manifest` writes a whole manifest from a k3s release, the version of each upstream chart and the two PostgreSQL images by tag. It needs helm and the network, and looks up everything else: each chart's images at the chart's default tag, the k3s image, its airgap tarballs and image list, the tools, and every digest and sha256.

```bash
go -C e2e run ./cmd/manifest -k3s <k3s release> -cert-manager <version> -cloudnative-pg <version> \
  -plugin-barman-cloud <version> -opentelemetry-collector <version> \
  -postgresql <image>:<tag> -rollout-from <image>:<tag> >versions/<name>.yaml
```

The first lines of each manifest give the command that made it, so running that command again writes the same file, unless a tag has moved since. To change a version, run the command with the new version rather than editing the file.

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
| `manifest.yaml` | The manifest the run used. |
| `timing.md` | One row per line of the scenario and of `always.feature`: its result, how long it took, the time since the event it refers to, and what it measured. It is printed at the end of the log too. |
| `cucumber.json`, `junit.xml` | The scenario's steps and results. |
| `always.cucumber.json`, `always.junit.xml` | The same for `always.feature`. |
| `state.txt` | `docker ps`, the kernel's last messages, the last log lines of every container, the images on each node, the nodes, pods, events and CNPG objects, and the alert history. After a failure it is also printed at the end of the log. |
| `k3s-1.log` to `k3s-3.log` | Each node's whole log, k3s's and the kubelet's, with docker's timestamps. When a node never turns Ready while the run builds the cluster, its log then has the kernel's stack of each k3s thread that waits in the kernel and the stack of every goroutine of k3s, before k3s starts again. |
| `disks.md` | Each node's [data filesystem](#each-nodes-data-filesystem): its size, the most it held and when, what it held at the end, and what each volume holds then. Also the runner's free space before the run. |
| `client.log` | The client's log: one line per read, write, connect and attempt, with the address it used ([format](../e2e/client/main.go)). |
| `pgfallback.md` | The [pgfallback report](#the-pgfallback-report), for scenarios with a `pgfallback has been healthy` line. |
| `evidence.<part>.json`, `evidence.desired.json`, `prove.<node>.json`, `prove.desired.json`, `host-check.<node>.json` | What the evidence scripts printed, for scenarios that run them. `cnpg-report` [draws](report.md#run) the prove and host-check documents; host-check needs its desired document from [`desired.sh --source host-check`](desired.md) first. An `evidence.sh` document of one part has only that part. |

Start with `timing.md`: the first row with a failure names the line that failed, and its *Measured* column gives what was seen. Then read `state.txt` for what the cluster looked like at the end.

## Run scenarios in CI

On GitHub, [`e2e.yml`](../.github/workflows/e2e.yml) runs every scenario on an amd64 runner, one job each, in parallel. It runs on demand only. It takes four inputs:

- `variant`: a directory of `variants/`; empty for the samples.
- `scenarios`: scenario tags, comma-separated; empty for every scenario. A tag that no scenario has, or that a variant run leaves out, stops the run before any job.
- `manifest`: a file of `versions/`, such as `v1.34.yaml`; `latest.yaml` by default.
- `arm64`: `true` runs every job on an arm64 runner too. Off by default.

```bash
gh workflow run e2e.yml --ref <branch>                               # every scenario of the samples on amd64
gh workflow run e2e.yml --ref <branch> -f variant=my-variant
gh workflow run e2e.yml --ref <branch> -f scenarios=fence,switchover # two scenarios
gh workflow run e2e.yml --ref <branch> -f manifest=v1.34.yaml        # other versions
gh workflow run e2e.yml --ref <branch> -f arm64=true                 # also on arm64
gh run download <run id> --name switchover-X64                       # one job's results
```

`gh workflow run` prints the run's URL, which ends in its id. Keep it: several runs on the same branch and commit look alike in `gh run list`. The run's name gives the variant, the manifest and the scenarios.

Each job uploads its `results/` as `<scenario>-<arch>`, where the arch is `X64` or `ARM64`, also when the scenario failed. Besides the run's directory it holds `outcome`, the outcome of the job's Scenario step, `success` or `failure`, and `exit-code`, the e2e container's exit code. A job stays green when its scenario fails. The last job, the verdict, decides the run: for each scenario the run picked, it compares the result with the variant's [`gaps.md`](#a-variants-gaps), none for the samples, and prints a table of them in the run's summary. A scenario `gaps.md` lists must fail on the line its row names and on no other, with exit code 1 and every line of `always.feature` passed; every other must pass; a scenario without a result does not match. The run is green only when every one matches.

In any other CI, run one job per scenario with a matrix variable and this one line, with `$VARIANT` empty for the samples and `$MANIFEST` empty for the default:

```bash
./e2e.sh "$SCENARIO" "$VARIANT" "$MANIFEST"
```

The job needs docker that can run privileged containers, Go 1.27 and the inotify limit. Keep `results/` as the job's artifact. An unset or empty `$SCENARIO` exits 2, so the job fails rather than pass without running anything.

## What a run does

What runs outside k3s in production runs as a container next to the k3s nodes, never as a pod. Everything below runs in the inner docker of the one e2e container:

| Inside k3s | Outside k3s, as containers |
|---|---|
| k3s: CoreDNS, Traefik, local-path, metrics-server, from k3s's airgap images | `dns`: CoreDNS for every name below |
| cert-manager, with a ClusterIssuer of the company CA, or an Issuer per Certificate | `acme.example.test`: OpenBao as the company CA, serving ACME |
| The CNPG operator and the barman-cloud plugin | `s3.example.test`: versitygw as the [S3 store](#the-store), with TLS |
| The CNPG cluster `pg` | `otel`, `prometheus`, `alertmanager`, `grafana` `.example.test`: the [monitoring](monitoring.md) |
| The OTel collectors | `orders-app.test`: the client, reading and writing through [pgfallback](https://github.com/djosh34/pgfallback), or GORM in a variant run |

1. Checks the inotify limit and starts its own dockerd. Checks that the runner's disk has room, then makes each node's [data filesystem](#each-nodes-data-filesystem).
2. Builds the `client` image, then creates the outside containers, copies their files in with `docker cp`, and starts them. The company CA gets a new root on every run.
3. Downloads the manifest's k3s airgap tarball of the runner's architecture and checks its sha256. Starts three k3s servers with embedded etcd, `k3s-1.example.test` to `k3s-3.example.test`, on the manifest's k3s image, with [`samples/k3s/`](../samples/k3s) or the variant's `k3s/`. Each node has the tarball in `/var/lib/rancher/k3s/agent/images/` before k3s starts, so k3s imports its own images from it. Each node runs [`e2e/node-init.sh`](../e2e/node-init.sh), which restarts k3s when it exits, so the pods outlive k3s as they do under systemd. It keeps k3s's process ID in `/run/k3s.pid`, for a scenario that restarts k3s.
4. Applies the settings' `k3s/patches.yaml`, such as one CoreDNS pod per node, and waits for each patched object and for Traefik.
5. Makes the Secrets only the run knows, then installs the releases of [`samples/charts/releases.yaml`](../samples/charts/releases.yaml), or of the variant's, in order, each with the manifest as its first values file. Before each, it writes the manifest's version and repository of each upstream chart into the dependencies of its copy of the chart, and `helm dependency build` downloads them.
6. Waits until the cluster is healthy, takes a first backup, and waits until Prometheus has every source's metrics. It then checks that every image on the nodes is one the manifest names, as the [manifest](#the-version-manifest) says, and names the instances: the primary, replica 1 and replica 2.
7. Runs the scenario. Its first When line starts the client.
8. After a failed line, [ends the outages](#after-a-failed-line) still in place.
9. Runs `always.feature`, also after a failed scenario, and writes the results. Its last line checks the images on the nodes again.
10. Removes the nodes, then unmounts their data filesystems and deletes the images.

The client gets its own certificate from the company CA by ACME. For the whole scenario it reads and writes through `pgfallback`, or GORM in a variant run, every 0.25 s, each with a 10 s limit, and connects to each node's rw port alone every 0.25 s. `Given no writes` starts it without writes.

### Each node's data filesystem

Each node keeps its local-path volumes, the instances' data and WAL, on a filesystem of its own, as the [first list](go-live/disk-and-bucket.md#the-data-disk) asks of a production node. In every run, of the samples and of a variant, the run makes one 4 GiB ext4 image per node in `/e2e-disks`, a volume of the e2e container, allocated in full up front. It mounts each on a loop device and binds it into its node at `/var/lib/rancher/k3s/storage` before k3s starts; [`node-init.sh`](../e2e/node-init.sh) refuses to start k3s without it. etcd, the images and the logs stay on the node's own volume. The mount outlives a node's `docker stop` and `docker start`, so a killed node keeps its data.

The kubelet reports this filesystem in `kubelet_volume_stats_*`, so `CNPGDataDiskFull` and the dashboard's data disk panels see a node's own disk. A full one stops only that node's PostgreSQL: the runner's disk gave the three images their 12 GiB at the start.

Before it makes them, the run checks that the runner's disk has 20 GiB free: 12 GiB for the images and 8 GiB for the rest of the run. With less it stops with that message. Every 5 s it notes how much each filesystem holds; `disks.md` gives the most and the end. At the end it removes the nodes, unmounts the filesystems and deletes the images. If the run is killed, removing the e2e container and its volume releases them too.

### The store

`s3.example.test` is [versitygw](https://github.com/versity/versitygw) with its own users and versioning. Its bucket is the one [disk-and-bucket.md](go-live/disk-and-bucket.md#a-bucket-nothing-can-delete-from) asks for: versioned, with that page's bucket policy. The policy lets CNPG's keys, in the Secret `backup-creds`, list, read and write, and refuses everyone the deletes and the changes of versioning, lifecycle and the policy. versitygw has no lifecycle rules at all. Its root keys pass every policy, as an account's root does, so only the run has them; CNPG never does.

When it starts the store, the run checks with CNPG's keys that a write and a read work, and that a delete and a change of versioning, of the policy or of the bucket are refused. A run whose store does not hold these limits stops there.

### After a failed line

Each scenario ends its own faults in its own lines. When a line fails partway, the run first ends the outages still in place, then runs `always.feature`:

- it starts the killed nodes, and waits up to 5 min for the API server before the steps that need it;
- it brings back a stopped or paused store;
- it removes the firewall rule of a cut-off instance;
- it unfences the fenced instances;
- it resumes paused replay;
- it stops an unfinished drain and uncordons its node.

Nothing else is undone, and the run does none of CNPG's work: no promote, rejoin or pod deletion. `always.feature` then checks that the cluster gets healthy on its own. An instance whose node was restarted lost its firewall rule and its paused replay with the node, so those are left alone. The timing table has a row for this step with what it did.

## Add or change a scenario

1. Write the scenario in a `.feature` file of `samples/features/`, with its own tag: lower-case words with dashes. Use only the lines of the [vocabulary](#vocabulary).
2. Add the tag to `SCENARIOS` in the `plan` job of [`e2e.yml`](../.github/workflows/e2e.yml).
3. Check both without a cluster: `go -C e2e test ./...`. `TestFeaturesUseTheVocabulary` fails on a line outside the vocabulary, on a tag used twice, and when the list in `e2e.yml` differs from the tags.
4. Run it: `./e2e.sh <tag>`, or the [workflow](#run-scenarios-in-ci) with `-f scenarios=<tag>`.

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
| `<ALERT> fires`, `resolves for <who> < N s` | Waits up to N s until the alert fires, or no longer fires. Without a limit, checks now. |
| `<ALERT> fired`, `has not fired`, `may fire for <who>` | Whether it fired since the scenario started; `may fire` allows it. |
| `<ALERT> <severity> fires for <who>`, and the other alert words | The same, for the alert of that severity, `warning` or `critical`. Not with `may fire`. |
| `Alertmanager gets <ALERT> for <role>` | Sends Alertmanager the critical alert for 2 min, as the rule evaluator would. An event. |
| `Alertmanager sends`, `mutes <ALERT> [<severity>] for <who> < N s` | Waits until a notification of it as firing reached the receiver, or Alertmanager holds it muted. |
| `Alertmanager sends the resolved <ALERT> [<severity>] for <who> < N s` | Waits until a notification of it as resolved reached the receiver. |
| `no writes` | The client does not write in this scenario. |
| `host-check.sh fails these checks on every node:` | With a table of `check` and `value`: on every node, each of these checks fails with its value. Other checks are not looked at. |
| `host-check.sh passes every check on every node but these:` | With a table of `check`: on every node, every check not in the table passes. Each check in the table must exist. |

`is` may be `are`, and `has` may be `have`. An event comes only in a Given or When line, a check only in a Given or Then line. The event names an `after the` or `since the` line can use are the words in quotes below. An event's time is when the run finished doing it.

**Roles:** `the primary`, `replica 1` and `replica 2`, named when the cluster is ready; `the new primary`, the instance that became primary last; `another instance`, any instance but the primary; `a replica`, an instance other than the one that became primary last. An alert line names who the alert is for: a role, by the alert's `pod` label; `the cluster`, an alert of the cluster `pg` without a `pod`; or `the server certificate` or `the replication certificate`, by the `name` label of an alert about the chart's Certificate `pg-server` or `pg-replication`. `may fire` and `the alerts are healthy` tell alerts apart by their name and `pod` only. Any alert name works; a scenario names an alert only where its condition truly makes it fire, as a variant's own alerts on the same disk or certificate.

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
| `the instance image is changed` | `helm upgrade` of `pg` with the manifest's `postgresql.imageName`. "change" |
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
| `<role>'s data disk is filled to <n> %` | A ballast file on the data filesystem of the instance's node, allocated, brings it to that share used. A second line grows the same file. |
| `the ballast is removed` | Deletes the ballast file. |
| `sessions are held on <role> up to <n> % of max_connections` | psql sessions as `postgres` on the instance, each in `pg_sleep`, bring the sessions `cnpg_backends_total` counts to that share; they go on while the scenario does. |
| `the held sessions are ended` | `pg_terminate_backend` of each held session. |
| `an unapproved role is created on <role>`, `the unapproved role is dropped` | `create role e2e_unapproved`, which the compliance query does not expect; `drop role` on the current primary. |
| `the exporter's grants are revoked on <role>`, `are given back on <role>` | Revokes, or grants, `cnpg_metrics_exporter` its two grants on `pg_ident_file_mappings`, which the compliance query needs. |
| `the server certificate is reissued for <n> days`, and `the replication certificate` | Shortens the company CA's ACME role to that lifetime with a PATCH, has cert-manager issue the chart's Certificate again, as `cmctl renew` does, waits for the new certificate, then sets the role back to 90 days and runs `kubectl cnpg reload`. |
| `the server certificate is reissued`, and `the replication certificate` | The same with the role's own 90 days. |
| `desired.sh runs`, `prove.sh runs`, `host-check.sh runs` | Runs the script as its doc says: `desired.sh` against the cluster, `prove.sh` and `host-check.sh` as root on every node. |
| `the <part> part of evidence.sh runs` | Runs `evidence.sh --part <part>` against the cluster: `client-ca`, `logins`, `postgres`, `pods`, `tls` or `kubernetes`. |
| `new k3s CAs are stored in etcd` | Runs k3s's `rotate-default-ca-certs.sh` in the e2e container on a copy of the first node's CAs, copies the new CAs to that node, and runs `k3s certificate rotate-ca` there, which leaves `server/tls/dynamic-cert-regenerate` on that node. It creates the same file on the other nodes. The scenario keeps the new CAs for the lines below. |
| `k3s is restarted on node <n>` | Stops k3s on the node `k3s-<n>` with SIGTERM, as `systemctl restart k3s` does; `node-init.sh` starts it again 5 s later, and the pods keep running. The line ends once the new k3s runs. |

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
| `every instance is on the new image` | Every postgres container runs the manifest's `postgresql.imageName` and is ready. |
| `every image on the nodes is from the manifest` | Every image `crictl images` lists on each node is pinned by the manifest, by repository and digest, or is one of its `k3s.images`, by repository and tag, imported by k3s. It names every other image. |
| `wal_keep_size is <n>MB on every instance` | `show wal_keep_size` gives it. |
| `<role>'s WAL is archived` | The file it switched away from is archived. |
| `<role>'s WAL is waiting for the store` | It has WAL files marked `.ready`. |
| `the WAL <role> needs is gone from <role>` | After two checkpoints, the WAL file the first instance needs is gone from the second's `pg_wal`. |
| `the backup is done` | The backup's phase is completed. |
| `the commit is done` | The started insert ended and succeeded. |
| `<role>'s metrics are arriving` | Prometheus has its `cnpg_collector_up` 1 from the last 30 s. |
| `the replica lag panel is healthy` | The dashboard's Replica lag panel shows no alert state: the query it shows in red, while `CNPGReplicaLag` fires, has no result. With `for N s` it holds the whole time. The timing table gives the most each replica reported since the last event, of `cnpg_replica_lag_seconds` and of CNPG's own `cnpg_pg_replication_lag`. |
| `compliance is healthy`, `compliance on pg-restore is healthy` | Every instance reported the four compliance checks as 0 in the last 30 s. |
| `the exporters are healthy` | Every exporter answered in the last 30 s with its query metrics. |
| `cnpg_pg_database_xid_age is exported for every database` | On every instance, the metric arrived in the last 60 s for each database with `datallowconn`, as CNPG's query reads them, and for no other. |
| `the <part> part of evidence.sh passes`, `prove.sh passes` | No violation in that part; every probe as in the desired document, on every node. |
| `no acknowledged write is lost`, `... lost in pg-restore` | Stops the client; every write it got acknowledged is in `e2e_writes` on the primary, or of `pg-restore`. |
| `the alerts are healthy` | No alert fires. The alerts the scenario says `fired` or `fires` fired, and no other did but those it says `may fire`. |
| `the dashboard is healthy` | Every panel of the dashboard gives a value through Grafana. |
| `node <n> is on the new CAs` | On `k3s-<n>`, the API server and the kubelet serve a certificate of the new server CA, etcd's client and peer ports one of the new etcd server and peer CAs, each checked against the new CA alone. The node's admin kubeconfig has a client certificate of the new client CA, which its API server takes. The API server's proxy certificate is of the new request-header CA, and a request through it to metrics-server works, as does one to the node's kubelet. |
| `etcd is healthy` | etcd lists three members, none a learner, and each member, asked over gRPC on its node's client port, gives its status without errors and knows a leader. The run asks with the first node's etcd client certificate. |
| `every node is Ready` | Each node's `Ready` condition is `True`. |

Measures and since lines:

| Line | Holds when |
|---|---|
| `reading is healthy < N s` | The client never went N s without a successful read. |
| `writing is healthy < N s` | The client never went N s without an acknowledged write, until the writes stop. A scenario's own limit also replaces the one in `always.feature`. With `after the <event>`: an acknowledged write sent after the event, by N s after it. |
| `writing has been down since the <event>` | No write sent since the event was acknowledged. |
| `<role> and <role> have been on the dashboard since the <event>` | The dashboard's Instances panel, evaluated every 15 s since the event as a dashboard that refreshes would show it, never lacked either instance at four evaluations in a row, 60 s of refreshes. An exporter can answer once without its query metrics after a change of the `Cluster`, which drops the instance from one evaluation; on-call need not see that. The timing table gives the longest run of evaluations without one. |
| `pgfallback has been healthy since the <event>` | The [pgfallback report](#the-pgfallback-report) finds nothing `pgfallback` must not do. |

### The pgfallback report

[`e2e/fallback.go`](../e2e/fallback.go) reads `client.log` from the event on and writes `pgfallback.md`: when rw took no connection, when reads and writes failed and worked again, and every failed read and write. The line fails when a read address served a read or write that started more than 1 s after rw was back and after the pool's own attempt at rw had worked; when that attempt worked more than 1 s plus `connect_timeout` per rw address and one more after rw was back; or when the log's last read or write did not work on rw.
