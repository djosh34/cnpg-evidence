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

Exit 0 when `violations` is empty, 1 when not, 2 on any error (bad input, a missing tool, a failed or forbidden `kubectl` or `psql` call), with nothing on stdout. A run takes about 15 seconds on a small cluster.

## What happens

1. **Read the desired state.** It checks that `desired.yaml` has every key it needs, with the right types, and reads the certificates of `--ca`.
2. **Find the instance pods.** Kubernetes runs each PostgreSQL instance as a pod: one or more containers that share an address on the cluster's overlay network, separate from the node addresses. A namespace groups objects such as pods, Secrets and permissions under one name; it does not separate the network. The pods of the cluster carry the labels `cnpg.io/cluster=<name>` and `cnpg.io/podRole=instance`, and the `Cluster` object names the primary. Each pod should set `hostUsers: false`: then the container's uid 26 is another uid on the host, and a host user with uid 26 is nobody inside it.
3. **Read PostgreSQL.** On the primary, as `postgres` over `kubectl exec` and inside `BEGIN READ ONLY ... ROLLBACK`, it lists every role and which roles hold each special right. A role attribute such as `SUPERUSER` counts when the role can `SET ROLE` to a role that has it. A privilege, such as those of the built-in `pg_*` roles or `EXECUTE` on a file function, also counts when inherited. Replicas are physical copies, so the catalog of the primary holds for all. Every psql call runs with an empty environment and names the user `postgres`, the database `postgres`, CNPG's socket directory `/controller/run` and port 5432, so no `PG*` variable of the container changes what it connects to or how.
4. **Read the logins.** On every instance it reads `pg_hba_file_rules` and `pg_ident_file_mappings`; on the primary, the roles that can log in and every database. PostgreSQL uses the first pg_hba line that matches a connection, so the script walks the lines in order for three kinds of connection: the pod's unix socket, TCP with TLS and TCP without. A line for all addresses decides the connection and ends the walk; a line limited to some addresses decides only for those, and the walk goes on for the rest. The result is, per database, which role gets in and how.
5. **Read the client CA.** The `Cluster` names the Secret whose `ca.crt` PostgreSQL uses to check client certificates, so that Secret decides which certificates can log in. Its certificates must be exactly those of `--ca`.
6. **Read TLS.** On every instance it reads PostgreSQL's `ssl` and `ssl_min_protocol_version`, and makes one TLS handshake with `openssl s_client` to the metrics port 9187 inside the pod.
7. **Read the NetworkPolicies.** A NetworkPolicy selects pods by label and lists who may connect to them, by pod and namespace labels or by address range. Once any policy selects a pod, all other incoming connections are dropped, and several policies add up. NetworkPolicy never filters connections from the node itself (host processes and hostNetwork pods) to a pod on that node; pods on the same node are filtered as usual. For each instance pod the script takes the policies that select it and names each allowed source:
   - `outside`: any address that is not a pod.
   - `other nodes`: the tunnel addresses. Under flannel, the k3s default, a connection from another node itself arrives from that node's `flannel.1` address, the first address of its pod range. A LoadBalancer connection that enters on another node arrives the same way.
   - `loadbalancer`: the svclb pods. k3s servicelb runs one per node in `kube-system`, and a connection it forwards can arrive from the svclb pod's address.
   - Then the cluster's own pods, the operator, the OTel namespace and every namespace.
8. **Read the Services.** A Service sends connections to the pods its selector matches in its own namespace, or to the addresses in its EndpointSlices, which can be written by hand for a Service without a selector, in any namespace. The script lists every Service whose selector matches an instance pod or whose EndpointSlices hold an instance pod's address, with every port it opens, and every host port of the instance pods. A NodePort opens the port on every node, an external IP makes every node answer on that address, and a host port opens the port on the pod's node.
9. **Read hostNetwork pods.** A pod with `hostNetwork: true` uses its node's network directly. Containers get `NET_BIND_SERVICE` unless it is dropped. A container that keeps it can bind a port below 1024 on the node if it is privileged, runs as root (also when neither `runAsUser` nor `runAsNonRoot: true` is set), or can regain the capability (no `allowPrivilegeEscalation: false`).
10. **Ask the API server who holds which right.** Kubernetes permissions are Roles (in one namespace) and ClusterRoles, given to users, groups and ServiceAccounts by RoleBindings and ClusterRoleBindings. A ServiceAccount is the identity a pod runs as; whoever can run a pod in a namespace can use that namespace's ServiceAccounts. Every subject of every binding is asked with a SubjectAccessReview, one per subject, verb and resource. The API server answers a review as it would answer the subject itself and stores nothing. A review names the subject's groups: a ServiceAccount is in `system:serviceaccounts`, `system:serviceaccounts:<namespace>` and `system:authenticated`, a user in `system:authenticated`, and a group is asked as a probe user in that group and `system:authenticated`. A Role can limit a verb to named objects, so existing objects are asked by name: the instance pods, the `Cluster`, every Secret, the NetworkPolicies, the nodes, `system:masters`, `cluster-admin` and the ServiceAccounts of CNPG and cert-manager. `system:masters` is the group whose members skip all authorization checks; the k3s admin certificate is in it. All reviews go in one List to one `kubectl create`; a failed review fails the run, so an error is never taken as a "no". Each yes comes with the API server's reason, which names the binding that allowed it.
11. **Compare.** Each section's facts are compared with the expected values from `desired.yaml` and the fixed CNPG facts, giving one sentence per violation.

## Output

Example, shortened and shown as YAML:

```yaml
kind: actual
source: evidence
collected_at: "2026-01-02T03:04:05Z"
cluster: {name: pg, namespace: databases}
status: pass
violations: []
postgres: {superusers: [postgres], can_replicate: [postgres, streaming_replica], roles: [billing, cnpg_metrics_exporter, orders, postgres, streaming_replica], ...}
databases: {orders: {owner: orders, connect: [PUBLIC, orders], logins: {orders: {common_names: [orders-app.test]}, ...}}, ...}
client_ca: {secret: client-ca, certificates: [{name: CN=example-ca, sha256_fingerprint: "2E:18:..."}]}
tls: {pg-1: {postgresql: TLSv1.3, metrics: TLSv1.3}, ...}
network_policy: {pg-1: {outside: [5432], other nodes: [5432], own node: [all], ...}, ...}
ports: {services: {databases/pg-read-lb: {type: LoadBalancer, selector: "cnpg.io/cluster=pg,cnpg.io/podRole=instance", traffic_policy: Local, ports: ["5433 -> 5432"], node_ports: [], health_check_port: present, external_ips: []}, ...}, host_ports: {pg-1: [], ...}}
kubernetes: {namespaces: {databases: {exec_into_pods: [group:system:masters, ...], ...}, ...}, request_certificates: [...], ...}
pods_sharing_host_uids: []
host_network_pods_that_can_bind_low_ports: []
software: {kubernetes: v1.x.y+k3s1, cnpg_operator: 1.x.y, barman_cloud_plugin: v0.x.y, postgresql: "x.y"}
details: {primary: pg-1, instances: [pg-1, pg-2, pg-3], pg_hba: [{number: 1, line: local all all peer map=local}, ...], ...}
```

- `kind`: `actual`, a document read from a live cluster.
- `source`: `evidence`.
- `collected_at`: when the script started reading, in UTC, ISO 8601, from the local clock.
- `cluster`: the `name` and `namespace` of the CNPG `Cluster`, from `desired.yaml`.
- `status`: `pass` when `violations` is empty, else `fail`.
- `violations`: one sentence each, starting with its rule, for example `rule 8: mallory can change secret client-ca in databases (allowed by RoleBinding "mallory/databases" of Role "secrets" to User "mallory")`. A Kubernetes rights violation ends with the reason the API server gave, which names the binding. Extra and missing things both count.

### `postgres`

- `superusers`, `can_create_roles`, `can_create_databases`, `can_replicate`, `can_bypass_row_security`: roles that have the attribute after `SET ROLE`. Expected `postgres`, and `streaming_replica` in `can_replicate`.
- `can_run_server_programs`, `can_read_all_data`, `can_write_all_data`: through `pg_execute_server_program`, `pg_read_all_data` or `pg_write_all_data`, by `SET ROLE` or inheritance. Expected `postgres`.
- `can_read_server_files`: through `pg_read_server_files` or `EXECUTE` on `pg_read_file`, `pg_read_binary_file` or the server-side `lo_import`. Expected `postgres` and `streaming_replica`, which CNPG lets read files for `pg_rewind`.
- `can_write_server_files`: through `pg_write_server_files` or `EXECUTE` on the server-side `lo_export`. Expected `postgres`.
- `have_password`: roles with a stored password. Expected none.
- `can_log_in`: roles with `LOGIN`. Expected every role in `roles`.
- `roles`: every role except the built-in `pg_*` ones. Expected `postgres`, `streaming_replica`, `cnpg_metrics_exporter` and the role of each database in `desired.yaml`. `app` is a rule 4 violation, even without `LOGIN`.

`postgres` is a superuser without a password. CNPG needs it for every operation, and it logs in only over the pod's unix socket by peer authentication: PostgreSQL asks the kernel for the uid of the connecting process, and only uid 26 inside the pod maps to `postgres`.

### `databases`

Per database, and `replication` for physical replication:

- `owner`: expected the role from `desired.yaml`, `postgres` for CNPG's own databases.
- `connect`: who holds `CONNECT`; PostgreSQL grants it to `PUBLIC` on every new database. Reported, not compared: pg_hba decides who reaches which database.
- `logins.<role>.common_names`: certificate logins, the CNs pg_ident maps to the role. Expected the `clientCNs`, and for `streaming_replica` the replication CN and CNPG's fixed `streaming_replica`.
- `logins.<role>.os_users`: peer logins over the pod's socket. Expected `postgres` as `postgres` and as `cnpg_metrics_exporter`.
- `logins.<role>.password`, `logins.<role>.no_authentication`: a password or trust line reaches the role. Never expected.
- `allows_connections: false`: the database takes no connections (`template0`).

### `client_ca`

- `secret`: the Secret the `Cluster` takes client CAs from. Expected `caSecret`.
- `certificates`: subject and SHA-256 fingerprint of each certificate in its `ca.crt`. Expected exactly those of `--ca`.

### `tls`

Per instance pod:

- `postgresql`: the lowest TLS version PostgreSQL accepts, or `off`. Expected `TLSv1.3`, CNPG's default (rule 1).
- `metrics`: the TLS version port 9187 answers with, or `none`. Expected a version (rule 5).

### `network_policy`

Per instance pod, each source and the ports it may connect to:

- `outside`: an `ipBlock` `0.0.0.0/0` with every node's pod range in `except`, so it matches addresses outside the cluster and no pod. Expected 5432.
- `other nodes`: the node tunnel addresses. Expected 5432.
- `own node`: always all ports.
- `loadbalancer`: the svclb pods of the rw Service. Expected 5432.
- `pg pods`: the cluster's own pods, for replication and failover checks. Expected 5432 and 8000.
- `<namespace> operator`: the operator pods. Expected 8000.
- `<namespace>`: all pods of a namespace selected by name. Expected only the OTel namespace, on 9187.
- `other namespaces`: a source that admits every namespace. Expected none.
- `everyone`: a rule without a source, or no policy at all. Never expected.
- A source it cannot name appears as its raw JSON and is a violation.

### `ports`

Rule 9: the ways into PostgreSQL besides a login.

- `services.<namespace>/<name>`: every Service in any namespace that reaches an instance pod, by its selector or by an address in its EndpointSlices:
  - `type`: `ClusterIP`, `NodePort` or `LoadBalancer`.
  - `selector`: its selector as `key=value` pairs, or `none` for a Service whose EndpointSlices are written by hand.
  - `traffic_policy`: `externalTrafficPolicy`, `Cluster` or `Local`, or `none` for a Service that takes no traffic from outside the cluster.
  - `ports`: every port as `port -> targetPort`, with the protocol in front when it is not TCP, such as `UDP/53 -> 53`. A Service without a selector ignores `targetPort` and sends each port to the port of the same name in its EndpointSlices: the arrow then shows that port, `all` for a slice port without a number, which means every port, or `none` when no slice has it. A Service without ports, which only a headless one may be, limits no port and shows `all`.
  - `node_ports`: the NodePorts of its ports. A NodePort leads to PostgreSQL on every node.
  - `health_check_port`: `present` when it has a `healthCheckNodePort`, else `none`. Kubernetes gives one to every LoadBalancer with traffic policy `Local`, for load balancers to ask over HTTP whether the node has a ready pod; it does not lead to PostgreSQL, so its number is not shown.
  - `external_ips`: its `externalIPs`. Every node answers on them.

  Expected exactly: CNPG's `<cluster>-rw`, `<cluster>-r` and, with more than one instance, `<cluster>-ro`, ClusterIP on 5432 to the primary, every instance and the replicas; the rw LoadBalancer on 5432 to the primary with traffic policy `Cluster`; and, when `desired.yaml` sets `readLoadBalancer`, the read LoadBalancer on its port to every instance with traffic policy `Local` and a health check port. No NodePort and no external IP. Another Service, a missing one, or any field that differs is a violation.
- `host_ports.<pod>`: the host ports of each instance pod's containers, as `hostPort -> containerPort`. Expected none.

### `kubernetes`

Per right, the subjects the API server says yes for, as `system:serviceaccount:<ns>:<name>`, `group:<name>` or a user name. Each right equals PostgreSQL superuser, gets a certificate from cert-manager, opens a port on the nodes, or reaches PostgreSQL past the NetworkPolicy (rule 9). Only `system:masters`, the operator, the plugin, the instance ServiceAccount, the API server, cert-manager and its cainjector, and the Kubernetes and k3s controllers may hold them. In the `cert-manager` namespace its webhook may also, since it keeps its own serving CA there.

- `namespaces.<ns>`: for the cluster's, the operator's and cert-manager's namespace:
  - `exec_into_pods`: get or create on `pods/exec` or `pods/attach`, patch on `pods/ephemeralcontainers`; by name for the instance pods.
  - `change_pods`: update or patch on pods, which can swap a container's image; by name for the instance pods.
  - `run_pods`: create, update or patch pods, ReplicationControllers, Deployments, StatefulSets, DaemonSets, ReplicaSets, Jobs or CronJobs. A pod can run as any ServiceAccount of its namespace and mount its volumes.
  - `read_secret.<name>`, `read_secret.all (list)`, `read_secret.all (watch)`: get on that Secret, or list and watch on all.
  - `write_secret.<name>`, `write_secret.all (create)`: update or patch on that Secret, or create any. This includes the client CA Secret, which decides which certificates can log in.
  - `port_forward` (cluster namespace only): get or create on `pods/portforward` of the instance pods. The kubelet opens a port-forward inside the pod, so the NetworkPolicy does not apply. A holder beyond the subjects above breaks rule 9.
  - `create_pg_tokens` (cluster namespace only): tokens for the instance ServiceAccount.
  - `change.<kind>` (cluster namespace only): create, update or patch. The keys are `clusters` (the `Cluster`, by name), `databases`, `databaseroles`, `subscriptions`, `poolers`, `objectstores`, `endpoints` and `endpointslices` (they decide which pods the cluster's Services send connections to), and `networkpolicies`, where delete counts too.
- `request_certificates`: create cert-manager Certificates or CertificateRequests, or change Certificates, in any namespace, or `run_pods` where such a ServiceAccount lives. cert-manager signs what these objects ask for. Only `system:masters`, cert-manager and the controllers may.
- `proxy_to_nodes`: get on `nodes/proxy`, the kubelet API of every node.
- `impersonate`: impersonate users, groups, ServiceAccounts, `system:masters` or a CNPG or cert-manager ServiceAccount.
- `bind_or_escalate_roles`: bind or escalate Roles, ClusterRoles or `cluster-admin`.
- `change_webhooks`: write mutating or validating webhook configurations.
- `can_open_node_ports`: `run_pods` in any namespace (a pod can use `hostPort` or `hostNetwork`), create, update or patch Services (servicelb gives a LoadBalancer port on every node), or Ingresses, or the IngressRoutes or IngressRouteTCPs of Traefik, which k3s installs by default (an ingress controller serves them on the nodes' ports). Expected only the subjects listed above.
- `operator_reads_secrets_in`, `plugin_reads_secrets_in`: namespaces where the operator or plugin ServiceAccount can get, list or watch Secrets, or get one by name. Expected only the operator's and the cluster's namespace (rule 7).
- `not_served`: present only when the cluster does not serve `ingressroutes.traefik.io` or `ingressroutetcps.traefik.io`; those it lists are not asked.

### Pods

- `pods_sharing_host_uids`: instance pods without `hostUsers: false`. Expected none. Fewer instance pods than `cluster.instances` is a violation too.
- `host_network_pods_that_can_bind_low_ports`: hostNetwork pods in any namespace that can bind a port below 1024, as in step 8. Expected none.

### `software` and `details`

- `software`: Kubernetes, operator, plugin and PostgreSQL versions. Reported, not compared.
- `details`: the primary, the instance pods, the pg_hba and pg_ident lines (one list per instance when they differ, which is a violation), and `pg_hba_not_understood`, `pg_ident_not_understood`: lines it cannot interpret, such as a regular expression or an `ldap` method. Each is a violation.
- Each pg_hba and pg_ident line is `{number, line}`. `number` is its place in the order PostgreSQL matches the lines (`rule_number` or `map_number`), so the same line in another place has another number. It is `null` for a line with an error.

## Code

| Path | What it does |
|---|---|
| `evidence.sh` | Reads the input, runs each part, assembles the document |
| `psql/psql.sh` | Runs one SQL file as postgres in an instance pod, with an empty environment |
| `postgres/` | `postgres.sql`: roles and their rights |
| `logins/` | `rules.sql` (every instance), `catalog.sql` (primary), `logins.jq`: the first-match walk |
| `client-ca/`, `tls/` | The client CA Secret; TLS settings and the metrics handshake |
| `network/` | `network.jq`: policies to named sources, per pod |
| `ports/` | `ports.jq`: the Services that reach the instance pods, and their host ports |
| `kubernetes/` | `subjects.jq`, `needs.jq` (which questions), `reviews.jq` (the questions as SubjectAccessReviews), `answers.jq` (the answers and their reasons), `kubernetes.jq` (grouping) |
| `pods/`, `host-network/`, `software/` | Instance pods, hostNetwork pods, versions |
| `violations/` | `expected.jq`: the expected values; one `.jq` per section with its rules; `violations.sh` joins their sentences |

Every file has a `*.test.sh` next to it with a stubbed `kubectl` and fixed inputs; `scripts/test.sh` runs them all. The SQL files need a running PostgreSQL and are not covered by these tests.

## Limits

- The pg_hba and pg_ident views show the files on disk, not proof that the server loaded them. `prove.sh` tries the logins.
- Connections with GSSAPI encryption are not walked; CNPG sets up no Kerberos.
- A SubjectAccessReview goes through every authorizer of the API server, but does not show which users are in a group or hold `system:masters` certificates. Only subjects named in a binding are asked, so a user whose groups come from the authenticator shows only under those groups.
- Named questions cover the objects that exist at the time of the run.
