# CNPG least-privilege access: samples and evidence

Sample manifests for a CloudNativePG (CNPG) cluster that accepts only certificate logins, and three scripts that show the rules below hold on a running cluster.

## What the scripts assume

- k3s with its default flannel, servicelb, local-path provisioner and network policy controller.
- Hosts with SELinux and rpm.
- CNPG with the barman-cloud plugin.
- [`desired.yaml`](desired.yaml) describes the cluster: its name and namespace, the client CA Secret, the LoadBalancer, the namespaces of the operator and the OTel collectors, the replication certificate and the databases. The sample chart, `evidence.sh` and `desired.sh` read it.

## Rules

`evidence.sh` starts each violation with the number of the rule it breaks.

1. A client logs in only with a certificate signed by the client CA. Its CN maps to exactly one role, and that role reaches exactly one database.
2. No password login works, with or without TLS.
3. No application role can create roles or has any other special attribute.
4. There is no `app` role or database.
5. Pods in other namespaces cannot connect to the instance pods on PostgreSQL (5432), the status port (8000) or metrics (9187), except the CNPG operator on 8000 and the OTel collectors on 9187.
6. A host user with the postgres uid cannot reach the socket, the data or the ServiceAccount token of an instance.
7. The CNPG operator and the barman-cloud plugin cannot read Secrets outside the operator's and the cluster's namespaces.
8. Only `system:masters`, CNPG's components, cert-manager and its cainjector, the API server and the Kubernetes and k3s controllers hold a right that equals PostgreSQL superuser or opens a port on the nodes. Rights that equal superuser include exec into the instance pods, reading or writing their Secrets and changing CNPG objects. Of these subjects, only `system:masters`, cert-manager and the controllers can request certificates. No hostNetwork pod can bind a port below 1024.

## Run

All three scripts print one JSON document on stdout and logs on stderr. Exit 0 means every check passed, 1 that at least one failed, 2 that the script could not run; then stdout is empty.

```bash
# Anywhere with a cluster-admin kubeconfig (on a k3s server node,
# KUBECONFIG=/etc/rancher/k3s/k3s.yaml). Rules 1 to 5, 7, 8 and the pod side of 6.
yq -o=json desired.yaml | bash scripts/evidence/evidence.sh --ca client-ca.pem > evidence.json

# On every node, as root. The host side of rule 6, and who can bind low ports.
bash scripts/host-check/host-check.sh > host-check.json

# On one node that runs an instance, as root, with a cluster-admin kubeconfig
# (on a k3s server node, KUBECONFIG=/etc/rancher/k3s/k3s.yaml).
# Real login and access attempts that must fail.
bash scripts/prove/prove.sh > prove.json

# Anywhere with bash, jq and openssl. The desired documents of the three scripts,
# and the differences between a desired and an actual document.
yq -o=json desired.yaml | bash scripts/desired/desired.sh --ca client-ca.pem > evidence.desired.json
bash scripts/desired/compare.sh evidence.desired.json evidence.json

# Anywhere with bash, jq, openssl and python3. The unit tests of all three scripts,
# with kubectl and psql stubbed.
bash scripts/test.sh
```

`client-ca.pem` holds the CAs that may sign client certificates, including the CA of the `issuer` in `samples/chart/values.yaml`: the same certificates as `ca.crt` in the client CA Secret. Each script's doc lists its options, the tools it needs and every key of its output.

## How the scripts fit together

- `evidence.sh` reads the live state through the API server and PostgreSQL, and compares it with `desired.yaml`. It shows rules 1 to 5, 7 and 8, and the pod side of rule 6. It only reads.
- `host-check.sh` reads one node: accounts with the postgres uid or gid, sudoers, directory modes, SELinux, subordinate ids and low ports. It shows the host side of rule 6. It only reads.
- `prove.sh` tries what rules 1, 2, 5 and 6 forbid: password logins, certificate logins as the wrong role, connections from a pod in another namespace, and file and socket access as the host postgres uid. Each attempt must fail with the expected denial, and two control attempts must succeed.
- `desired.sh` builds, from `desired.yaml` alone, a document of the same shape as each script's output that holds the desired values. `compare.sh` lists where an actual document differs from it. The scripts' own checks stay the verdict.

## Files

| Path | What it is | Doc |
|---|---|---|
| `desired.yaml` | The desired state of the cluster, read by the chart, `evidence.sh` and `desired.sh` | [samples.md](docs/samples.md) |
| `samples/` | Helm chart rendered from `desired.yaml`, operator and plugin values, RBAC for both | [samples.md](docs/samples.md) |
| `scripts/evidence/evidence.sh` | Who can do what in PostgreSQL and Kubernetes, and every rule the live state breaks | [evidence.md](docs/evidence.md) |
| `scripts/host-check/host-check.sh` | Accounts, modes, SELinux, subordinate ids and low ports on one node | [host-check.md](docs/host-check.md) |
| `scripts/prove/prove.sh` | Login, connection and host-uid attempts that must fail | [prove.md](docs/prove.md) |
| `scripts/desired/` | The desired documents of the three scripts, and the comparison with an actual document | [desired.md](docs/desired.md) |
| `report/` | The page that draws a desired and an actual image for each piece of evidence | [report/README.md](report/README.md) |
| `scripts/lib/` | Logging and exit helpers shared by the scripts | |
| `scripts/test.sh` | Runs the `*.test.sh` next to every part of the three scripts | |
| `.github/workflows/ci.yml` | Runs `scripts/test.sh` and the page tests on every pull request and push to `main` | |
| `.shellcheckrc` | ShellCheck settings for the scripts | |
| `LICENSE` | Apache License 2.0 | |
