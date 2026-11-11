# evidence.sh

`scripts/evidence/evidence.sh` shows who can do what to the CNPG cluster, in PostgreSQL and in Kubernetes, and lists every [rule](../README.md#rules) the live state breaks. It only reads. The `evidence` scenario runs it.

## Run

Anywhere with a cluster-admin kubeconfig (on a k3s server, `KUBECONFIG=/etc/rancher/k3s/k3s.yaml`):

```bash
yq -o=json samples/desired.yaml | bash scripts/evidence/evidence.sh --ca client-ca.pem > evidence.json
```

- **stdin:** `samples/desired.yaml` as JSON. Every expected value comes from it or from the fixed CNPG facts in `scripts/evidence/violations/expected.jq`, never from the live `Cluster`.
- **`--ca`:** the CAs in PEM that may sign client certificates, the same as `ca.crt` of the client CA Secret.
- **Needs** bash, `kubectl`, `jq`, `openssl`, `timeout`, `base64` and the whole `scripts/` directory. In the instance pods it runs only `psql`, as `postgres` over the socket, inside `BEGIN READ ONLY`.

Exit 0 when `violations` is empty, 1 when not, 2 on any error, with nothing on stdout. It takes about 15 s.

## What it reads

- **PostgreSQL**, on the primary: every role, which roles hold each special right after `SET ROLE` or by inheritance, and every database. On every instance: `pg_hba_file_rules` and `pg_ident_file_mappings`. pg_hba must match line for line, since PostgreSQL uses the first match; pg_ident must match in any order.
- **The client CA:** the certificates of the Secret the `Cluster` names must be exactly those of `--ca`.
- **TLS:** each instance's `ssl_min_protocol_version`, and a handshake with port 9187 through `kubectl port-forward`.
- **Pods:** every instance pod has `hostUsers: false`, and there are `cluster.instances` of them.
- **Kubernetes:** every subject of every binding is asked with a SubjectAccessReview, per right below. Existing objects are asked by name, so Roles limited to named objects show. A failed review fails the run.

## Output

```yaml
kind: actual
source: evidence
collected_at: "2026-01-02T03:04:05Z"
cluster: {name: pg, namespace: databases}
status: pass
violations: []
postgres: {superusers: [postgres], roles: [billing, cnpg_metrics_exporter, orders, postgres, streaming_replica], ...}
certificate_logins: [{common_name: orders-app.test, role: orders, database: orders}, ...]
client_ca: {secret: client-ca, certificates: [{name: CN=example-ca, sha256_fingerprint: "2E:18:..."}]}
tls: {pg-1: {postgresql: TLSv1.3, metrics: TLSv1.3}, ...}
kubernetes: {superuser_in_cluster_namespace: [group:system:masters, ...], ...}
pods_sharing_host_uids: []
software: {kubernetes: v1.x.y+k3s1, cnpg_operator: 1.x.y, barman_cloud_plugin: v0.x.y, postgresql: "x.y"}
details: {primary: pg-1, instances: [pg-1, pg-2, pg-3], pg_hba: [{number: 1, line: ...}, ...], pg_ident: [...]}
```

- `violations`: one `{path, sentence}` each. The sentence starts with its rule, such as `rule 7: mallory can get PostgreSQL superuser through rights in databases (allowed by RoleBinding "mallory/databases" of Role "secrets" to User "mallory")`. `path` names the value it is about; `cnpg-report` takes each image's verdict from it.
- `postgres`: per right, the roles that hold it. `superusers`, `can_create_roles`, `can_create_databases`, `can_bypass_row_security`, `can_run_server_programs`, `can_read_all_data`, `can_write_all_data` and `can_write_server_files` expect `postgres` only. `can_replicate` and `can_read_server_files` also expect `streaming_replica`; `can_read_ident_view` and `can_run_ident_function` also expect `cnpg_metrics_exporter`. `have_password` expects none, `can_log_in` every role. `roles` and `databases` expect CNPG's and those of `desired.yaml`; `app` is a rule 4 violation.
- `certificate_logins`: per certificate CN, the role and database the expected pg_hba and pg_ident lines give it.
- `tls`: per instance, PostgreSQL's lowest TLS version, expected `TLSv1.3`, and the metrics port's, expected a version.
- `software`: reported, not compared.
- `details`: the pg_hba and pg_ident lines as `{number, line}`, where `number` is PostgreSQL's match order; one list per instance when they differ.

### kubernetes

Per right, the subjects the API server says yes for: `system:serviceaccount:<ns>:<name>`, `group:<name>` or a user.

| Key | Rights |
|---|---|
| `superuser_in_cluster_namespace` | In the cluster's namespace: exec, attach or ephemeral containers on the instance pods, or changing them; creating pods or any workload; reading Secrets or writing ConfigMaps; tokens of the instance ServiceAccount; writing the `Cluster`, `databases`, `databaseroles` or `objectstores` |
| `create_certificates` | Creating cert-manager Certificates or CertificateRequests, or writing Issuers or ClusterIssuers |
| `write_routes` | Writing Ingresses, or Traefik IngressRoutes or IngressRouteTCPs where served |
| `run_pods` | Creating or changing pods or any workload, anywhere |
| `become_cluster_admin` | `nodes/proxy`; impersonation; bind or escalate; webhook configurations; k3s HelmCharts or HelmChartConfigs |
| `operator_reads_secrets_in`, `plugin_reads_secrets_in` | Namespaces where they can read Secrets (rule 6) |

The allowed subjects, in `expected.jq`. Each holds one of these rights on a k3s cluster with the samples, and the cluster cannot run without it:

| Subject | May hold | Why |
|---|---|---|
| `group:system:masters` | all | The admin group; the k3s admin certificate is in it |
| The operator's and the plugin's ServiceAccounts | all but `create_certificates` | They run the instances, their Secrets, pods and backups |
| The instance ServiceAccount, named like the cluster | all but `create_certificates` | The instances read their own Secrets |
| `kube-apiserver` | all but `create_certificates` | The API server |
| cert-manager | all | It signs certificates and writes their Secrets |
| cert-manager's cainjector | all but `create_certificates` | It writes CA bundles into webhook configurations |
| `system:kube-controller-manager`, `k3s-cloud-controller-manager` | all | The controller manager; k3s's ServiceLB runs the LoadBalancer pods |
| The controllers in `kube-system`: `clusterrole-aggregation-controller`, the workload controllers (`cronjob`, `daemon-set`, `deployment`, `job`, `replicaset`, `replication`, `statefulset`), `generic-garbage-collector`, `namespace-controller`, `persistent-volume-binder`, `resourcequota-controller`, `legacy-service-account-token-cleaner`, `root-ca-cert-publisher` | all | Each creates, counts, changes or deletes objects of every namespace |
| `local-path-provisioner-service-account` | all | It runs the pods that make volumes |
| k3s's Helm jobs `helm-traefik` and `helm-traefik-crd` | all | k3s binds them to cluster-admin |
| Traefik's ServiceAccount `traefik` | read Secrets only | It reads the certificates of the routes it serves |

## Limits

- The pg_hba and pg_ident views show the files, not that the server loaded them; `prove.sh` tries the logins.
- A review does not show who is in a group. Only subjects named in a binding are asked.
- Named questions cover the objects that exist during the run.
- The SQL files are not covered by `scripts/test.sh`, which stubs `kubectl` and `psql`.
