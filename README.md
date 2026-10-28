# CNPG least-privilege access: samples and evidence

Sample manifests for a CloudNativePG (CNPG) cluster that accepts only certificate logins, and three scripts that show the rules below hold on a running cluster. `cnpg-report` draws the scripts' output as images.

## What the scripts assume

- k3s with its default flannel, servicelb, local-path provisioner and network policy controller.
- Hosts with SELinux and rpm.
- CNPG with the barman-cloud plugin.
- [`desired.yaml`](desired.yaml) describes the cluster: its name and namespace, the client CA Secret, the rw and read LoadBalancers, the namespaces of the operator and the OTel collectors, the replication certificate and the databases. The sample chart, `evidence.sh` and `desired.sh` read it.

## Rules

`evidence.sh` starts each violation with the number of the rule it breaks.

1. A client logs in only with a certificate signed by the client CA, over TLS 1.3. Its CN maps to exactly one role, and that role reaches exactly one database. The metrics port answers only over TLS.
2. No password login works, with or without TLS.
3. No application role can create roles or has any other special attribute.
4. There is no `app` role or database.
5. A host user with the postgres uid cannot reach the socket or the data of an instance.
6. The CNPG operator and the barman-cloud plugin cannot read Secrets outside the operator's and the cluster's namespaces.
7. Only `system:masters`, CNPG's components, cert-manager and its cainjector, the API server, the Kubernetes and k3s controllers and k3s's Helm install jobs can get PostgreSQL superuser through rights in the cluster's namespace, write Ingresses or Traefik routes, run pods, or become cluster-admin. Rights that equal superuser include exec into the instance pods, reading or writing their Secrets and changing CNPG objects; Traefik may also read the Secrets, for the certificates of the routes it serves. Of these subjects, only `system:masters`, cert-manager, the controllers and the Helm install jobs can create certificates.
8. On every node, only root can bind ports below 1024 or read the k3s credentials, k3s encrypts Secrets in its datastore, and k3s enforces NetworkPolicies.

## Run

All three scripts print one JSON document on stdout and logs on stderr. Exit 0 means every check passed, 1 that at least one failed, 2 that the script could not run; then stdout is empty.

```bash
# Anywhere with a cluster-admin kubeconfig (on a k3s server node,
# KUBECONFIG=/etc/rancher/k3s/k3s.yaml). Rules 1 to 4, 6, 7 and the pod side of 5.
yq -o=json desired.yaml | bash scripts/evidence/evidence.sh --ca client-ca.pem > evidence.json

# On every node, as root. The host side of rule 5, and rule 8.
bash scripts/host-check/host-check.sh > host-check.json

# On one node that runs an instance, as root, with a cluster-admin kubeconfig
# (on a k3s server node, KUBECONFIG=/etc/rancher/k3s/k3s.yaml).
# Real login and access attempts that must fail.
yq -o=json desired.yaml | bash scripts/prove/prove.sh > prove.json

# Anywhere with yq, bash, jq and openssl. The desired documents of the three scripts.
yq -o=json desired.yaml | bash scripts/desired/desired.sh --ca client-ca.pem > evidence.desired.json

# On any x86_64 Linux host, with no network. A desired and an actual image
# for each piece of evidence. See docs/report.md for getting the binary.
cnpg-report --desired evidence.desired.json --out images/ evidence.json

# Anywhere with bash, jq, openssl and python3. The unit tests of all three scripts,
# with kubectl and psql stubbed.
bash scripts/test.sh
```

`client-ca.pem` holds the CAs that may sign client certificates, including the CA of the `issuer` in `samples/chart/values.yaml`: the same certificates as `ca.crt` in the client CA Secret. Each script's doc lists its options, the tools it needs and every key of its output.

## How the scripts fit together

- `evidence.sh` reads the live state through the API server and PostgreSQL, and compares it with `desired.yaml`. It shows rules 1 to 4, 6, 7 and the pod side of rule 5. It only reads.
- `host-check.sh` reads one node: SELinux, accounts with the postgres uid or gid, directory modes, the k3s credentials and secrets encryption, low ports and the network policy controller. It shows the host side of rule 5 and rule 8. It only reads.
- `prove.sh` tries what rules 1, 2 and 5 forbid: password logins, a certificate login as the wrong role, and socket and data access as the host postgres uid. Each attempt must fail with the expected denial, and one control attempt must succeed.
- `desired.sh` builds, from `desired.yaml` alone, a document of the same shape as each script's output that holds the desired values. The scripts' own checks stay the verdict.
- `cnpg-report` draws one desired and one actual document of the same script as PNG images, a desired and an actual image for each piece of evidence. On the actual image, every value or right beyond the desired document is red, and the image says Passed or Failed. It needs no cluster, network or OS library, so the scripts can run on the cluster and the images can be drawn elsewhere from the JSON files.

## Upgrade from v0.1.0

v0.2.0 adds the optional read LoadBalancer and a rule 9 for the ways into PostgreSQL besides a login, which later versions dropped again, and drops `rwLoadBalancer.create`, the sample chart's NodePorts and the cluster flags of `prove.sh`, which now reads `desired.yaml` on stdin. Delete a Service of the rw or read name that was made outside the chart before the upgrade, and remove an old NodePort once after it. [upgrade.md](docs/upgrade.md) lists every step and the changed images.

## Files

| Path | What it is | Doc |
|---|---|---|
| `desired.yaml` | The desired state of the cluster, read by the chart, `evidence.sh` and `desired.sh` | [samples.md](docs/samples.md) |
| `samples/` | Helm chart rendered from `desired.yaml`, operator and plugin values, RBAC for both | [samples.md](docs/samples.md) |
| `scripts/evidence/evidence.sh` | Who can do what in PostgreSQL and Kubernetes, and every rule the live state breaks | [evidence.md](docs/evidence.md) |
| `scripts/host-check/host-check.sh` | SELinux, accounts, modes, k3s credentials and low ports on one node | [host-check.md](docs/host-check.md) |
| `scripts/prove/prove.sh` | Login and host-uid attempts that must fail | [prove.md](docs/prove.md) |
| `scripts/desired/` | The desired documents of the three scripts | [desired.md](docs/desired.md) |
| `report/` | `cnpg-report`, which draws a desired and an actual image for each piece of evidence: its page, build and tests | [report.md](docs/report.md), [report/README.md](report/README.md) |
| `scripts/lib/` | Logging and exit helpers shared by the scripts | |
| `scripts/test.sh` | Runs the `*.test.sh` next to every part of the three scripts | |
| `.github/workflows/ci.yml` | Runs `scripts/test.sh`, the page tests and the test of the built `cnpg-report` on every pull request and push to `main`, and as part of `release.yml` | |
| `.github/workflows/release.yml` | On a pushed tag `v*`, runs `ci.yml`, pushes the tested `cnpg-report` as the image `ghcr.io/djosh34/cnpg-report:<tag>`, then pulls it, copies the binary out and renders the clean samples | [report.md](docs/report.md#get-the-binary) |
| `.shellcheckrc` | ShellCheck settings for the scripts | |
| `LICENSE` | Apache License 2.0 | |
