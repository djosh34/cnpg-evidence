# Upgrade

What changes from one release to the next, and what to do before and after the upgrade. From v0.1.0, follow both sections, the older one first.

## From v0.2.0 to v0.3.0

v0.3.0 changes the sample chart so that a lost primary node fails over by itself, adds a metric for role and mapping changes, cuts the scripts to the checks the rules need, and adds alert rules and a Grafana dashboard. The commands below use the cluster `pg` in `databases` of the example `desired.yaml`.

### Before the chart upgrade

- **Grants for the compliance query.** The chart gives CNPG's metrics exporter a new query, in the ConfigMap `<cluster>-compliance` that the `Cluster` names in `monitoring.customQueriesConfigMap`. It reads `pg_ident_file_mappings` as `cnpg_metrics_exporter`, which needs two grants. A new cluster gets them from the chart's `postInitSQL`. On a running cluster, give them once on the primary, as [samples.md](samples.md#grants) shows; the replicas get them by replication. Until then the metric is missing, and v0.3.0's `evidence.sh` fails, since it expects exactly these grants.
- **Other field managers of the `Cluster`.** Helm 4 applies the chart server-side when the release was last applied that way; `helm get metadata pg -n databases` shows the release's `APPLY_METHOD`. If the `Cluster` was then ever changed with another tool, such as `kubectl replace`, the upgrade can fail with a field conflict. Run that `helm upgrade` once with `--force-conflicts`, a flag Helm 3 does not have. A field that only the other tool set stays in the `Cluster` after the upgrade, even when the chart no longer has it; step 3 below checks the one that matters here.

### The chart upgrade

The settings that change in the `Cluster`. [samples.md](samples.md#writes-reads-and-failover) explains each and what clients see on a node loss.

- **Streaming readiness is gone.** `probes.readiness: {type: streaming, maximumLag: 16Mi}` is removed, and readiness is CNPG's default again. With it, a lost primary node did not fail over, because the replicas had to pass a lag check that needs a primary. A running replica that falls behind now stays on the read port; `CNPGReplicaLag` in [monitoring.md](monitoring.md#replica-lag) watches it.
- **`failoverQuorum: true`** under `synchronous`. CNPG promotes only a replica that holds every confirmed commit, and keeps a `FailoverQuorum` object for that.
- **`synchronous_commit: remote_apply`.** A commit returns once one other instance has applied it, not only received it.
- **The startup check, `probes.startup: {type: streaming, maximumLag: 128Ki}`.** A replica that starts opens the read port only once it streams and its replay is within 128Ki of the WAL end the primary last reported. It is checked once, while the container starts.

Turn on `failoverQuorum` on its own first. Together with another setting change, the primary can reload its configuration before CNPG has created the `FailoverQuorum` object. That reload fails and is not retried: the primary keeps its old settings, and the next rollout waits.

1. In v0.2.0's chart, add `failoverQuorum: true` under `synchronous` in `samples/chart/templates/cluster.yaml`, and run `helm upgrade --install pg samples/chart -n databases -f desired.yaml` with it. Then check that the object exists and that every instance reports the same `cnpg.config_sha256`:

   ```bash
   kubectl get failoverquorum pg -n databases
   for pod in $(kubectl get pods -n databases -l cnpg.io/cluster=pg,cnpg.io/podRole=instance -o name); do
     echo "$pod"
     kubectl exec -n databases "$pod" -c postgres -- psql -Atc 'show cnpg.config_sha256' -c 'show synchronous_commit'
   done
   ```

   `failoverQuorum` changes no PostgreSQL setting, so the hash stays as it was.
2. Upgrade with v0.3.0's chart, the same `helm upgrade` command. Run the loop again: every instance must report the same new hash and `remote_apply`. An instance that still reports the old hash has not reloaded; when it is the primary, run `select pg_reload_conf()` there, then check again. In tests, this step restarted no pod.
3. Check that readiness is gone: `kubectl get cluster pg -n databases -o jsonpath='{.spec.probes.readiness}'` must print nothing. If it prints the old probe, another tool set it; remove it once:

   ```bash
   kubectl patch cluster pg -n databases --type=json -p '[{"op":"remove","path":"/spec/probes/readiness"}]'
   ```

### Outside the chart

[samples.md](samples.md#outside-the-chart) has four new settings outside the chart: one CoreDNS replica per node, since a failover waits on DNS when the only CoreDNS pod ran on the lost node; k3s secrets encryption; an audit policy; and the backup bucket. `host-check.sh` now fails on a server node without secrets encryption.

### Scripts

- **Eight rules.** Rule 5 (connections from other namespaces) and rule 9 (the ways into PostgreSQL besides a login) are gone. Rules 6, 7 and 8 are now 5, 6 and 7, and the new rule 8 covers the node settings `host-check.sh` checks. Rule 1 also covers TLS on the metrics port, which was a rule 5 violation. Violations start with the new numbers. See the [rules](../README.md#rules).
- **`evidence.sh` sections.** `network_policy`, `ports` and `host_network_pods_that_can_bind_low_ports` are gone, and so is the `databases` section with its walk through the login rules. `postgres.databases` lists every database, and the new `certificate_logins` lists each certificate name with the role its pg_ident line maps it to and the database the expected certificate pg_hba line of that role names. `postgres` adds `can_read_ident_view` and `can_run_ident_function` for the grants above.
- **`evidence.sh` Kubernetes rights.** Five rights replace `namespaces.<ns>` (the rights in the cluster's, the operator's and cert-manager's namespace), `request_certificates`, `proxy_to_nodes`, `impersonate`, `bind_or_escalate_roles`, `change_webhooks` and `can_open_node_ports`. `superuser_in_cluster_namespace` is asked in the cluster's namespace only; `create_certificates`, `write_routes` and `run_pods` in every namespace; and `become_cluster_admin` holds the node proxy, impersonation, role binding and webhook rights. The operator's and cert-manager's namespaces are no longer asked on their own, so cert-manager's webhook is no longer an allowed subject. Writing ConfigMaps in the cluster's namespace counts as superuser, since the instances run the queries of a ConfigMap. Writing Services, Subscriptions, Poolers, Endpoints, EndpointSlices and NetworkPolicies no longer counts, and `port_forward` is gone. The allowed subjects add k3s's Helm install jobs for Traefik, Traefik's ServiceAccount, which may read Secrets, and the `root-ca-cert-publisher` controller. [evidence.md](evidence.md#kubernetes) lists each with its reason.
- **`evidence.sh` and `prove.sh` on empty stdin** exit 2 with `stdin is empty: pipe in desired.yaml as JSON`.
- **`host-check.sh` checks.** Six checks replace the 13, all but `k3s-network-policy` with new ids: `selinux` (with the containerd setting), `postgres-account`, `dir-modes`, `k3s-secrets` (the kubeconfig, config files with a token, the server directory and secrets encryption), `low-ports` and `k3s-network-policy`. `subordinate-ids` is gone. `postgres-account` shows the group's members, sudoers lines and server packages in its `raw`, without failing on them. The collected facts drop `k3s_config`, `firewalld`, `subuid`, `subgid` and `getsubids`. See [host-check.md](host-check.md#checks).
- **`prove.sh` probes.** The connections from another namespace are gone, so `prove.sh` no longer creates a namespace or a pod, and `pod/pod.sh` is gone. So are the logins through the read LoadBalancer, the replication certificate's login as `streaming_replica` to the application database, the host uid's socket login at the host path (`uid-<uid> socket-host-path`; the one as the mapped uid stays), and the reads of the process environment and the ServiceAccount token. One control attempt is left. See [prove.md](prove.md).
- **Make the desired documents again** with v0.3.0's `desired.sh`. A saved v0.2.0 desired document has the old sections and checks, and does not match the new documents.
- **`compare.sh` is gone,** with `compare.jq`. `cnpg-report` compares the desired and the actual document when it draws an actual image; the rules of that comparison are in [report.md](report.md#the-comparison).

### Images

- **`evidence.sh`: 8 pairs and the versions image,** in place of 12 pairs and the versions image. 01 accounts stays; it adds who can read pg_ident under Other rights, and drops the Owns and Password login columns. 02 certificate logins is new; after the certificate names, it lists each database no certificate pg_hba line names. Login rules, client CA and encryption move from 02–04 to 03–05, container isolation from 07 to 06, and operator Secrets from 08 to 07. The four platform images 09–12 become one platform rights grid, 08. Versions move from 13 to 09. Network (05) and Services and host ports (06) are gone.
- **`host-check.sh`: one pair per check,** so six per node, named with the new ids, such as `host-check-node-a-selinux-actual.png` in place of `host-check-node-a-selinux-enforcing-actual.png`.
- **`prove.sh`: two pairs.** Connections from another namespace (02) are gone, and access as the host postgres uid moves from 03 to 02.

The full list is in [report.md](report.md#output-file-names).

### Monitoring

`samples/monitoring/` is new: ten alert rules for Prometheus or the Mimir ruler, a route and inhibition rules for Alertmanager, and a Grafana dashboard. Nothing of it runs in the Kubernetes cluster. Before loading the rules, set the namespace and cluster name in their `cnpg_sample:database` rule. The scrape of CNPG's exporter must add the labels `namespace`, `pod`, `cluster` and `node`, and the dashboard also reads cAdvisor and kube-state-metrics with the `leases` resource. [monitoring.md](monitoring.md) has the setup, the scrape example and what the rules cannot see.

### Seen in tests

- When the lost primary node also ran the barman-cloud plugin's pod, the failover took about 6 minutes instead of about one (see [samples.md](samples.md#writes-reads-and-failover)).
- After each primary change, replicas that had caught up reported minutes of replication lag for about 4 to 5 minutes, so `CNPGReplicaLag` can fire after a failover on a quiet cluster (see [monitoring.md](monitoring.md#what-the-rules-do-not-see)).

## From v0.1.0 to v0.2.0

What to do before and after that upgrade. The rules, sections and probes named here are those of v0.2.0; v0.3.0 dropped rule 9, the `ports` section, `port_forward`, `can_open_node_ports` and the `other-namespace` probes.

### Before the chart upgrade

- **`rwLoadBalancer.create` is gone.** The chart always puts the rw LoadBalancer in the `Cluster`, and CNPG creates it. Remove the key from your copy of `samples/chart/values.yaml`. A restore next to a running cluster now sets `--set rwLoadBalancer.name=pg-restore-rw-lb --set readLoadBalancer=null` in place of `--set rwLoadBalancer.create=false` (see [samples.md](samples.md#restore-into-a-new-cluster)).
- **A Service made outside the chart must go.** CNPG refuses a Service of the rw or read name that it did not create (`refusing to reconcile service: ..., not owned by the cluster`). Delete such a Service before `helm upgrade`. Its port is closed until CNPG has made the new one.
- **The optional `readLoadBalancer` block.** `desired.yaml` can set `readLoadBalancer: {name, port}`, a read port on every node that leads only to the instance on that node. The example sets `pg-read-lb` on 5433. Leave the block out for no read port. `evidence.sh`, `prove.sh` and `desired.sh` read the same block, so give them the `desired.yaml` the chart used. See [samples.md](samples.md#loadbalancers) for how it behaves and how clients connect to it.

### The chart upgrade

- **No NodePorts.** Both LoadBalancers set `allocateLoadBalancerNodePorts: false`. A NodePort the rw Service (your `rwLoadBalancer.name`) had before stays after the upgrade, because Kubernetes keeps a NodePort it has allocated. Remove it once, then check that `kubectl get svc -n databases` shows no second port for the Service:

  ```bash
  kubectl patch service pg-rw-lb -n databases --type=json -p '[{"op":"remove","path":"/spec/ports/0/nodePort"}]'
  ```

  Until then, `evidence.sh` reports the NodePort under rule 9.
- **Readiness.** A replica is ready only while it streams and is less than 16Mi behind (`probes.readiness`). `synchronous` now spells out `dataDurability: required`, CNPG's default, so commits behave as before. The measured effect of a node loss is in [samples.md](samples.md#clients-on-the-read-port).

### Scripts

- **`prove.sh` reads the desired state on stdin,** as `evidence.sh` does: `yq -o=json desired.yaml | bash scripts/prove/prove.sh`. Without stdin it waits for input. It drops `--namespace`, `--cluster` and `--lb-service`, and exits 2 when given one; the names come from `cluster` and the LoadBalancer blocks of `desired.yaml`. `--node`, `--node-root` and `--postgres-uid` stay.
- **`prove.sh` probes.** The login probes and `other-namespace-lb` try every address and port of both LoadBalancers. The `other-namespace-nodeport` probe is gone; the ports section of `evidence.sh` shows that no NodePort exists.
- **Rule 9.** A new rule for the ways into PostgreSQL besides a login. `evidence.sh` has a new `ports` section: every Service in any namespace that reaches an instance pod, by its selector or its EndpointSlices, and the host ports of the instance pods. The Kubernetes rights add `port_forward` on the instance pods, and `can_open_node_ports` adds Traefik's `ingressroutetcps.traefik.io` where the cluster serves it.
- **Make the desired documents again** with v0.2.0's `desired.sh`. The evidence one gains `ports` and `port_forward`, and the prove one loses the NodePort probe. A saved v0.1.0 desired document makes the new Services extra, and the image fails.
- **`psql` runs with no caller environment.** Every psql call of `evidence.sh` and `prove.sh` names its host or socket, port, database and user, and no `PG*` variable of the caller or the image reaches it.

### Images

- **Image list.** The certificate names pair is gone; the accounts image shows the certificate names that log in as each account. Login rules, client CA, encryption and network move from 03–06 to 02–05, and the new Services and host ports pair is 06. 01 and 07 to 13 keep their names. The prove images get a Tried on column. The full list is in [report.md](report.md#output-file-names).
- **Marks.** Every yes or no is a square. A right beyond desired is a red filled square, and a protection that is off a red empty square. An extra row shows its name in red, and its other cells keep their own marks. Values the actual document lacks are not drawn; a value that means every port reads `all`, never empty. Each image that can show marks has a legend of them, and each actual image says Passed or Failed. See [report.md](report.md#reading-the-images).
- **A container run.** `cnpg-report` can run in its image with one `docker run` command, without copying the binary out (see [report.md](report.md#in-a-container)).
