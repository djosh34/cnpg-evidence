# evidence.sh

`scripts/evidence/evidence.sh` shows who can do what to the CNPG cluster, in PostgreSQL and in Kubernetes, and lists every [rule](../README.md#rules) the live state breaks. It only reads.

## Run

Anywhere with a cluster-admin kubeconfig (on a k3s server node, `KUBECONFIG=/etc/rancher/k3s/k3s.yaml`):

```bash
yq -o=json desired.yaml | bash scripts/evidence/evidence.sh --ca client-ca.pem > evidence.json
```

- stdin: the desired values from [`desired.yaml`](../desired.yaml) as JSON. The example converts `desired.yaml` with `yq` (mikefarah v4); any YAML-to-JSON converter works. Every expected value comes from these values or from fixed CNPG facts in `scripts/evidence/violations/expected.jq`, never from the live `Cluster`. [desired.sh](desired.md) builds the desired document from the same file.
- `--ca`: the CA certificates in PEM that may sign client certificates, including the CA of the `issuer` in `samples/chart/values.yaml`: the same certificates as `ca.crt` in the client CA Secret.
- Needs bash, `kubectl`, `jq`, `openssl` and `base64`, and the whole `scripts/` directory. The instance image needs `timeout` and `openssl` for the TLS handshake; without them `metrics` reads `none`.

Exit 0 when `violations` is empty, 1 when not, 2 on any error (empty stdin, bad input, a missing tool, a failed or forbidden `kubectl` or `psql` call), with nothing on stdout. A run takes about 15 seconds on a small cluster.

## What happens

1. **Read the desired state.** It checks that `desired.yaml` has every key it needs, with the right types, and reads the certificates of `--ca`.
2. **Find the instance pods.** Kubernetes runs each PostgreSQL instance as a pod: one or more containers that share an address on the cluster's overlay network, separate from the node addresses. A namespace groups objects such as pods, Secrets and permissions under one name; it does not separate the network. The pods of the cluster carry the labels `cnpg.io/cluster=<name>` and `cnpg.io/podRole=instance`, and the `Cluster` object names the primary. Each pod should set `hostUsers: false`: then the container's uid 26 is another uid on the host, and a host user with uid 26 is nobody inside it.
3. **Read PostgreSQL.** On the primary, as `postgres` over `kubectl exec` and inside `BEGIN READ ONLY ... ROLLBACK`, it lists every role, which roles hold each special right, and every database. A role attribute such as `SUPERUSER` counts when the role can `SET ROLE` to a role that has it. A privilege, such as those of the built-in `pg_*` roles or `EXECUTE` on a file function, also counts when inherited. Replicas are physical copies, so the catalog of the primary holds for all. Every psql call runs with an empty environment and names the user `postgres`, the database `postgres`, CNPG's socket directory `/controller/run` and port 5432, so no `PG*` variable of the container changes what it connects to or how.
4. **Read the login rules.** On every instance it reads `pg_hba_file_rules` and `pg_ident_file_mappings`. The pg_hba lines must be exactly the expected lines in the expected order, since PostgreSQL uses the first line that matches a connection. The pg_ident lines must be exactly the expected lines, in any order. From the pg_ident lines and the expected pg_hba lines that log in with a certificate, it builds the table of certificate name, role and database.
5. **Read the client CA.** The `Cluster` names the Secret whose `ca.crt` PostgreSQL uses to check client certificates, so that Secret decides which certificates can log in. Its certificates must be exactly those of `--ca`.
6. **Read TLS.** On every instance it reads PostgreSQL's `ssl` and `ssl_min_protocol_version`, and makes one TLS handshake with `openssl s_client` to the metrics port 9187 inside the pod.
7. **Ask the API server who holds which right.** Kubernetes permissions are Roles (in one namespace) and ClusterRoles, given to users, groups and ServiceAccounts by RoleBindings and ClusterRoleBindings. A ServiceAccount is the identity a pod runs as; whoever can run a pod in a namespace can use that namespace's ServiceAccounts. Every subject of every binding is asked with a SubjectAccessReview, one per subject, verb and resource. The API server answers a review as it would answer the subject itself and stores nothing. A review names the subject's groups: a ServiceAccount is in `system:serviceaccounts`, `system:serviceaccounts:<namespace>` and `system:authenticated`, a user in `system:authenticated`, and a group is asked as a probe user in that group and `system:authenticated`. A Role can limit a verb to named objects, so existing objects are asked by name: the instance pods, the `Cluster`, the Secrets and ConfigMaps of the cluster's namespace, the nodes, `system:masters`, `cluster-admin` and the ServiceAccounts of CNPG and cert-manager. `system:masters` is the group whose members skip all authorization checks; the k3s admin certificate is in it. All reviews go in one List to one `kubectl create`; a failed review fails the run, so an error is never taken as a "no". Each yes comes with the API server's reason, which names the binding that allowed it.
8. **Compare.** Each section's facts are compared with the expected values from `desired.yaml` and the fixed CNPG facts, giving one sentence per violation.

## Output

Example, shortened and shown as YAML:

```yaml
kind: actual
source: evidence
collected_at: "2026-01-02T03:04:05Z"
cluster: {name: pg, namespace: databases}
status: pass
violations: []
postgres: {superusers: [postgres], can_replicate: [postgres, streaming_replica], roles: [billing, cnpg_metrics_exporter, orders, postgres, streaming_replica], databases: [billing, orders, postgres, template0, template1], ...}
certificate_logins: [{common_name: orders-app.test, role: orders, database: orders}, ...]
client_ca: {secret: client-ca, certificates: [{name: CN=example-ca, sha256_fingerprint: "2E:18:..."}]}
tls: {pg-1: {postgresql: TLSv1.3, metrics: TLSv1.3}, ...}
kubernetes: {superuser_in_cluster_namespace: [group:system:masters, ...], create_certificates: [...], ...}
pods_sharing_host_uids: []
software: {kubernetes: v1.x.y+k3s1, cnpg_operator: 1.x.y, barman_cloud_plugin: v0.x.y, postgresql: "x.y"}
details: {primary: pg-1, instances: [pg-1, pg-2, pg-3], pg_hba: [{number: 1, line: local all cnpg_metrics_exporter peer map=cnpg_metrics_exporter}, ...], pg_ident: [...]}
```

- `kind`: `actual`, a document read from a live cluster.
- `source`: `evidence`.
- `collected_at`: when the script started reading, in UTC, ISO 8601, from the local clock.
- `cluster`: the `name` and `namespace` of the CNPG `Cluster`, from `desired.yaml`.
- `status`: `pass` when `violations` is empty, else `fail`.
- `violations`: one sentence each, starting with its rule, for example `rule 7: mallory can get PostgreSQL superuser through rights in databases (allowed by RoleBinding "mallory/databases" of Role "secrets" to User "mallory")`. A Kubernetes rights violation ends with the reason the API server gave, which names the binding. Extra and missing things both count.

### `postgres`

- `superusers`, `can_create_roles`, `can_create_databases`, `can_replicate`, `can_bypass_row_security`: roles that have the attribute after `SET ROLE`. Expected `postgres`, and `streaming_replica` in `can_replicate`.
- `can_run_server_programs`, `can_read_all_data`, `can_write_all_data`: through `pg_execute_server_program`, `pg_read_all_data` or `pg_write_all_data`, by `SET ROLE` or inheritance. Expected `postgres`.
- `can_read_server_files`: through `pg_read_server_files` or `EXECUTE` on `pg_read_file`, `pg_read_binary_file` or the server-side `lo_import`. Expected `postgres` and `streaming_replica`, which CNPG lets read files for `pg_rewind`.
- `can_write_server_files`: through `pg_write_server_files` or `EXECUTE` on the server-side `lo_export`. Expected `postgres`.
- `can_read_ident_mappings`: through `SELECT` on `pg_ident_file_mappings` or `EXECUTE` on its function, by `SET ROLE` or inheritance. Expected `postgres` and `cnpg_metrics_exporter`, which reads pg_ident for the [compliance metric](samples.md#compliance-metric).
- `have_password`: roles with a stored password. Expected none.
- `can_log_in`: roles with `LOGIN`. Expected every role in `roles`.
- `roles`: every role except the built-in `pg_*` ones. Expected `postgres`, `streaming_replica`, `cnpg_metrics_exporter` and the role of each database in `desired.yaml`. `app` is a rule 4 violation, even without `LOGIN`.
- `databases`: every database. Expected `postgres`, `template0`, `template1` and each database in `desired.yaml`. `app` is a rule 4 violation.

`postgres` is a superuser without a password. CNPG needs it for every operation, and it logs in only over the pod's unix socket by peer authentication: PostgreSQL asks the kernel for the uid of the connecting process, and only uid 26 inside the pod maps to `postgres`.

### `certificate_logins`

Who logs in with a certificate (rule 1): one row per certificate name, role and database.

- `common_name`: a certificate common name from a pg_ident line of a map that a certificate pg_hba line uses.
- `role`: the role that line maps it to.
- `database`: each database an expected pg_hba line opens to that role with that map, `all` for CNPG's pooler line, or `none`.

Expected: each `clientCNs` entry with its database's role and the database, and the replication CN and CNPG's fixed `streaming_replica` as `streaming_replica` to `postgres` and `replication`, and CNPG's pooler name. The pg_hba and pg_ident lines in `details` are the facts behind it, and they are compared line by line; this table shows what they allow.

### `client_ca`

- `secret`: the Secret the `Cluster` takes client CAs from. Expected `caSecret`.
- `certificates`: subject and SHA-256 fingerprint of each certificate in its `ca.crt`. Expected exactly those of `--ca`.

### `tls`

Per instance pod, rule 1:

- `postgresql`: the lowest TLS version PostgreSQL accepts, or `off`. Expected `TLSv1.3`, CNPG's default.
- `metrics`: the TLS version port 9187 answers with, or `none`. Expected a version.

### `kubernetes`

Per right, the subjects the API server says yes for, as `system:serviceaccount:<ns>:<name>`, `group:<name>` or a user name (rule 7), and where the operator and the plugin read Secrets (rule 6).

- `superuser_in_cluster_namespace`: rights in the cluster's namespace that equal PostgreSQL superuser: get or create on `pods/exec` or `pods/attach` or patch on `pods/ephemeralcontainers` of the instance pods; update or patch them, which can swap a container's image; create, update or patch pods, ReplicationControllers, Deployments, StatefulSets, DaemonSets, ReplicaSets, Jobs or CronJobs, since a pod can mount the instances' volumes and run as their ServiceAccount; get, update or patch each Secret, or list, watch or create Secrets; update or patch each ConfigMap, or create ConfigMaps, since the instances run the custom queries of a ConfigMap as `cnpg_metrics_exporter`; tokens for the instance ServiceAccount; and create, update or patch the `Cluster` (by name), `databases`, `databaseroles` and `objectstores`.
- `create_certificates`: create cert-manager Certificates or CertificateRequests, or update or patch Certificates, in any namespace. cert-manager signs what these objects ask for.
- `write_routes`: create, update or patch Ingresses, and Traefik IngressRoutes or IngressRouteTCPs where the cluster serves them, in any namespace. An ingress controller serves them on the nodes' ports.
- `run_pods`: create, update or patch pods or any of the workload kinds above, in any namespace. A pod can use `hostPort` or `hostNetwork`, and run as any ServiceAccount of its namespace.
- `become_cluster_admin`: get on `nodes/proxy`, the kubelet API of every node; impersonate users, groups, ServiceAccounts, `system:masters` or a CNPG or cert-manager ServiceAccount; bind or escalate Roles, ClusterRoles or `cluster-admin`; or write mutating or validating webhook configurations.
- `operator_reads_secrets_in`, `plugin_reads_secrets_in`: namespaces where the operator or plugin ServiceAccount can get, list or watch Secrets, or get one by name. Expected only the operator's and the cluster's namespace (rule 6).
- `not_served`: present only when the cluster does not serve `ingressroutes.traefik.io` or `ingressroutetcps.traefik.io`; those it lists are not asked.

The allowed subjects, in `scripts/evidence/violations/expected.jq`:

| Subject | May hold | Why |
|---|---|---|
| `group:system:masters` | every right | The cluster-admin group, which the k3s admin certificate is in |
| the operator's ServiceAccount | every right but `create_certificates` | It creates and runs the instances, their Secrets and their pods |
| the plugin's ServiceAccount | every right but `create_certificates` | It runs the backups next to the instances |
| the instance ServiceAccount, named after the cluster | every right but `create_certificates` | The instances read their own Secrets |
| `kube-apiserver` | every right but `create_certificates` | The API server |
| cert-manager | every right | It signs the certificates and writes their Secrets |
| cert-manager's cainjector | every right but `create_certificates` | It writes CA bundles into webhook configurations |
| the Kubernetes and k3s controllers | every right | They create pods and other objects from objects that other subjects write |
| k3s's Helm install jobs `helm-traefik` and `helm-traefik-crd` in `kube-system` | every right | k3s binds them to cluster-admin to install Traefik |
| Traefik's ServiceAccount `traefik` in `kube-system` | in `superuser_in_cluster_namespace`, only get, list and watch on Secrets | It reads Secrets in every namespace for the certificates of the routes it serves |

### Pods

- `pods_sharing_host_uids`: instance pods without `hostUsers: false` (rule 5). Expected none. Fewer instance pods than `cluster.instances` is a violation too.

### `software` and `details`

- `software`: Kubernetes, operator, plugin and PostgreSQL versions. Reported, not compared.
- `details`: the primary, the instance pods, and the pg_hba and pg_ident lines (one list per instance when they differ, which is a violation). A pg_hba line that differs from the expected line at its place, and a pg_ident line that is extra or missing, is a rule 1 violation. A line PostgreSQL cannot read shows with its error and differs too.
- Each pg_hba and pg_ident line is `{number, line}`. `number` is its place in the order PostgreSQL matches the lines (`rule_number` or `map_number`), so the same line in another place has another number. It is `null` for a line with an error.

## Code

| Path | What it does |
|---|---|
| `evidence.sh` | Reads the input, runs each part, assembles the document |
| `psql/psql.sh` | Runs one SQL file as postgres in an instance pod, with an empty environment |
| `postgres/` | `postgres.sql`: roles, their rights and the databases |
| `logins/` | `rules.sql`: the pg_hba and pg_ident lines of every instance |
| `client-ca/`, `tls/` | The client CA Secret; TLS settings and the metrics handshake |
| `kubernetes/` | `subjects.jq`, `needs.jq` (which questions), `reviews.jq` (the questions as SubjectAccessReviews), `answers.jq` (the answers and their reasons), `kubernetes.jq` (grouping) |
| `pods/`, `software/` | Instance pods, versions |
| `violations/` | `expected.jq`: the expected values and the allowed subjects; one `.jq` per section with its rules; `violations.sh` joins their sentences |

Every file has a `*.test.sh` next to it with a stubbed `kubectl` and fixed inputs; `scripts/test.sh` runs them all. The SQL files need a running PostgreSQL and are not covered by these tests.

## Limits

- The pg_hba and pg_ident views show the files on disk, not proof that the server loaded them. `prove.sh` tries the logins.
- A SubjectAccessReview goes through every authorizer of the API server, but does not show which users are in a group or hold `system:masters` certificates. Only subjects named in a binding are asked, so a user whose groups come from the authenticator shows only under those groups.
- Named questions cover the objects that exist at the time of the run.
