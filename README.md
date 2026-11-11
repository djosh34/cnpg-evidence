# CNPG least-privilege access: samples and evidence

Sample charts for a CloudNativePG (CNPG) cluster that accepts only certificate logins, scenarios that break a three-node k3s cluster built from them, and scripts that show the [rules](#rules) hold.

## Run a scenario

```bash
./e2e.sh switchover
```

- **Needs** docker, bash and Go 1.27, and the host's `fs.inotify.max_user_instances` at 1024 or more: `bash e2e/inotify.sh` raises it.
- **Results** go to `results/<scenario>-<time>/`. Exit 0 means the scenario passed.

`./e2e.sh` with no argument lists the scenarios. A run builds a three-node k3s cluster from `samples/` inside one container and takes 15 to 40 minutes; [docs/e2e.md](docs/e2e.md) says what it does and how to read its results.

## How to

| Action | Doc |
|---|---|
| Raise the host's inotify limit | [e2e.md](docs/e2e.md#raise-the-inotify-limit) |
| List the scenarios and run one | [e2e.md](docs/e2e.md#run-a-scenario) |
| Run scenarios in CI | [e2e.md](docs/e2e.md#run-scenarios-in-ci) |
| Read a run's results | [e2e.md](docs/e2e.md#read-the-results) |
| Change a chart, its values or the k3s settings | [samples.md](docs/samples.md#change-a-chart-its-values-or-the-k3s-settings) |
| Add or change a scenario | [e2e.md](docs/e2e.md#add-or-change-a-scenario) |
| Install the samples on a real cluster | [samples.md](docs/samples.md#install-on-a-cluster) |
| Collect the evidence and draw its images | [Evidence](#evidence) |
| Release a version | [release.md](docs/release.md) |

## Rules

The samples hold these rules, and `evidence.sh` starts each violation with the number of the rule it breaks.

1. A client logs in only with a certificate signed by the client CA, over TLS 1.3. Its CN maps to exactly one role, and that role reaches exactly one database. The metrics port answers only over TLS.
2. No password login works, with or without TLS.
3. No application role can create roles or has any other special attribute.
4. There is no `app` role or database.
5. A host user with the postgres uid cannot reach the socket or the data of an instance.
6. The CNPG operator and the barman-cloud plugin cannot read Secrets outside the operator's and the cluster's namespaces.
7. Only `system:masters`, CNPG's components, cert-manager and its cainjector, the API server, the Kubernetes and k3s controllers and k3s's Helm install jobs can get PostgreSQL superuser through rights in the cluster's namespace, write Ingresses or Traefik routes, run pods, or become cluster-admin. Of these, only `system:masters`, cert-manager, the controllers and the Helm install jobs can create certificates. [evidence.md](docs/evidence.md#kubernetes) lists the rights that count.
8. On every node, only root can bind ports below 1024 or read the k3s credentials, k3s encrypts Secrets in its datastore, and k3s enforces NetworkPolicies.

## Evidence

Each script prints one JSON document on stdout and logs on stderr. Exit 0 means every check passed, 1 that one failed, and 2 that the script could not run.

| Script | Where it runs | Rules | Doc |
|---|---|---|---|
| `scripts/evidence/evidence.sh` | Anywhere with a cluster-admin kubeconfig | 1 to 4, 6, 7, the pod side of 5 | [evidence.md](docs/evidence.md) |
| `scripts/host-check/host-check.sh` | On every node, as root | the host side of 5, and 8 | [host-check.md](docs/host-check.md) |
| `scripts/prove/prove.sh` | On a node that runs an instance, as root | 1, 2, 5, by trying | [prove.md](docs/prove.md) |
| `scripts/desired/desired.sh` | Anywhere | the desired document of each script | [desired.md](docs/desired.md) |
| `cnpg-report` | Any x86_64 Linux, offline | draws a desired and an actual image per piece of evidence | [report.md](docs/report.md) |

`bash scripts/test.sh` runs the unit tests of the scripts, with `kubectl` and `psql` stubbed.

## Files

| Path | What it is |
|---|---|
| `e2e.sh`, `e2e/` | Runs a scenario: the Go test, the code inside the container, the client and `inotify.sh` ([e2e.md](docs/e2e.md)) |
| `samples/` | The charts, values, k3s settings, monitoring and scenarios ([samples.md](docs/samples.md), [monitoring.md](docs/monitoring.md)) |
| `scripts/` | The evidence scripts and their tests |
| `report/` | `cnpg-report`: the page that draws the images, its build and tests ([report/README.md](report/README.md)) |
| `pgfallback/` | A Go package for pgx and GORM that falls back to the read port while no primary answers ([pgfallback.md](docs/pgfallback.md)) |
| `.github/workflows/` | `ci.yml` on every pull request and push to `main`; `e2e.yml`, every scenario on demand; `release.yml` on a pushed tag |

Licence: Apache License 2.0.
