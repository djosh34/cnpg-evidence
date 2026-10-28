# Samples

What is in `desired.yaml` and `samples/`, how to install it, and how to keep it right. The commands below pin the operator chart `cloudnative-pg` 0.29.1 and the plugin chart `plugin-barman-cloud` 0.8.1.

## Files

| File | What it is |
|---|---|
| [`desired.yaml`](../desired.yaml) | The desired state of the cluster: name, namespace and instances, the client CA Secret, the rw LoadBalancer name, the optional read LoadBalancer's name and port, the operator and OTel namespaces, the replication certificate names, and the databases with their role and client CNs. `evidence.sh` compares against it; the chart reads it as values. |
| [`samples/chart/`](../samples/chart) | A Helm chart that renders the `Cluster`, one `Database` per database, the server and replication `Certificate`s, the `<cluster>-bootstrap` Secret, the barman-cloud `ObjectStore` and one ingress `NetworkPolicy`. |
| [`samples/chart/values.yaml`](../samples/chart/values.yaml) | Chart-only settings: image, storage size, cert-manager issuer, object store, recovery. |
| [`samples/values-cnpg-operator.yaml`](../samples/values-cnpg-operator.yaml) | Values for the operator chart: chart RBAC off, `WATCH_NAMESPACE=cnpg-system,databases`. |
| [`samples/values-barman-cloud.yaml`](../samples/values-barman-cloud.yaml) | Values for the plugin chart: chart RBAC off. |
| [`samples/rbac-cnpg-operator.yaml`](../samples/rbac-cnpg-operator.yaml) | The operator's RBAC: a small ClusterRole for nodes, webhook configurations and cluster image catalogs, and the chart's namespaced rules bound only in `cnpg-system` and `databases`. |
| [`samples/rbac-barman-cloud.yaml`](../samples/rbac-barman-cloud.yaml) | The plugin's RBAC: cluster-wide `list,watch` on object stores, roles and role bindings, and the chart's other rules bound only in `databases`, with Secrets cut to `get,list,watch`. |

## What the chart renders

From the example `desired.yaml`:

```
pg_hba:
  hostssl orders  orders  all cert map=clients
  hostssl billing billing all cert map=clients
  host    all     all     all reject
pg_ident:
  cnpg_streaming_replica pg-replication streaming_replica
  clients orders-app.test     orders
  clients billing-app.test    billing
  clients billing-report.test billing
managed.roles: orders, billing (LOGIN, no other attribute, disablePassword: true)
Database objects: pg-orders, pg-billing
```

- Each `hostssl ... cert map=clients` line lets one role into one database with a client certificate; `clients` maps each CN to its role. The last line rejects every other TCP connection, with or without TLS.
- `cnpg_streaming_replica` is CNPG's map for replication logins; the chart adds the replication CN to it.
- The server and replication `Certificate`s carry the replication CN and `dnsNames` from `desired.yaml`, and the issuer from `values.yaml`.
- The `NetworkPolicy` selects every pod of the cluster, including its bootstrap and join Job pods, and admits 5432 and 8000 from the cluster's pods, 8000 from the operator pods, 9187 from the OTel namespace, and 5432 from outside the cluster, from the other nodes and from the svclb pods of the rw LoadBalancer.
- The `Cluster` has the rw LoadBalancer and, when `readLoadBalancer` is set, the read LoadBalancer, both without NodePorts (see [LoadBalancers](#loadbalancers)). Every commit waits for one other instance (`synchronous: {method: any, number: 1, dataDurability: required}`), and a replica is ready only while it streams and is less than 16Mi behind (`probes.readiness: {type: streaming, maximumLag: 16Mi}`).

To see the full output: `helm template pg samples/chart -n databases -f desired.yaml --dry-run=server`. The NetworkPolicy reads every node's `spec.podCIDR` from the cluster with `lookup`, so rendering without a cluster fails. A NetworkPolicy written by hand needs the same pod ranges, from `kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'`: each range goes into the `except` list of the `0.0.0.0/0` source, and its network address as `/32` becomes a source of its own. Under flannel, connections from another node itself arrive from that address, the node's `flannel.1` interface. No address range is fixed in the samples or the scripts.

## Install

Pods with `hostUsers: false` need a kernel with idmapped mounts on tmpfs.

1. Create the namespaces and apply both RBAC files:
   ```bash
   kubectl create namespace cnpg-system
   kubectl create namespace databases
   kubectl apply -f samples/rbac-cnpg-operator.yaml -f samples/rbac-barman-cloud.yaml
   ```
2. Install cert-manager in the namespace `cert-manager` with the release name `cert-manager`: `evidence.sh` expects the ServiceAccounts `cert-manager`, `cert-manager-cainjector` and `cert-manager-webhook` there. Create the issuer named in `samples/chart/values.yaml`. Check that it accepts the `usages` in `templates/certificates.yaml`; CNPG needs `client auth` on the replication certificate.
3. In `desired.yaml`, set:
   - `cluster`: the name, namespace and number of instances. The namespaces `databases` and `cnpg-system` are also fixed in `values-cnpg-operator.yaml` (`WATCH_NAMESPACE`) and in both RBAC files. Another namespace also needs `WATCH_NAMESPACE` and the RoleBindings in both RBAC files.
   - `caSecret`: a Secret in the cluster's namespace with `ca.crt` holding the CAs that may sign client certificates, including the CA of the `issuer` in `values.yaml`: the chart also uses this Secret as the server CA, and the replication certificate is checked against it. Give the full chain if there are intermediates. Create it by hand, never with `ca.key`: `kubectl create secret generic client-ca -n databases --from-file=ca.crt=client-ca.pem`. Pass the same file to `evidence.sh --ca`.
   - `rwLoadBalancer.name`: the rw LoadBalancer Service. The policy admits its svclb pods, the per-node pods in `kube-system` through which k3s servicelb forwards the LoadBalancer port.
   - `readLoadBalancer`: the name and port of the read LoadBalancer, or leave the block out for none.
   - `network.operatorNamespace`, `network.otelNamespace`: the namespaces of the operator and the OTel collectors.
   - `replication`: the CN and `dnsNames` of the server and replication certificates; `databases`: the databases, their roles and client CNs.
4. In `samples/chart/values.yaml`, set:
   - `issuer`: the cert-manager issuer from step 2, which signs the server and replication certificates.
   - `objectStore`: the bucket, endpoint and credentials Secret. Create that Secret in the cluster's namespace with the keys `ACCESS_KEY_ID` and `ACCESS_SECRET_KEY`.
   - `cluster.imageName` and `cluster.storageSize`.
5. Install the operator and the plugin with their values files:
   ```bash
   helm upgrade --install cnpg cloudnative-pg --repo https://cloudnative-pg.github.io/charts --version 0.29.1 \
     -n cnpg-system -f samples/values-cnpg-operator.yaml --wait
   helm upgrade --install barman-cloud plugin-barman-cloud --repo https://cloudnative-pg.github.io/charts --version 0.8.1 \
     -n cnpg-system -f samples/values-barman-cloud.yaml --wait
   ```
   To install from a file instead, fetch it with `helm pull cloudnative-pg --repo https://cloudnative-pg.github.io/charts --version 0.29.1`, the same for `plugin-barman-cloud`, and give the `.tgz` path in place of the chart name and `--repo`.
   The release names must stay `cnpg` and `barman-cloud`: the RBAC files name their ServiceAccounts `cnpg-cloudnative-pg` and `barman-cloud-plugin-barman-cloud`, and `evidence.sh` asks about those names.
6. Install the chart: `helm upgrade --install pg samples/chart -n databases -f desired.yaml`.
7. Restart the instances. The chart sets `hostUsers: false` through the `cnpg.io/podPatch` annotation on the `Cluster`, which applies only to new pods, so pods that already run keep host uid 26. Start a rolling restart, then check that every instance pod has `hostUsers: false` (`evidence.sh` checks it too):
   ```bash
   kubectl annotate cluster <cluster> -n databases kubectl.kubernetes.io/restartedAt="$(date -u +%FT%TZ)" --overwrite
   kubectl get pods -n databases -l cnpg.io/cluster=<cluster>,cnpg.io/podRole=instance \
     -o custom-columns=NAME:.metadata.name,HOSTUSERS:.spec.hostUsers
   ```
8. Point the OTel collectors at `https://<pod address>:9187/metrics`, with the CA of the server certificate as `ca_file` and one of its `dnsNames` as `server_name`.
   Run the collectors without `hostNetwork`, in the OTel namespace.
   If a collector does use `hostNetwork`, run it with `securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}`; otherwise `evidence.sh` lists it as able to bind a port below 1024 on its node.

CNPG creates both LoadBalancer Services and refuses a Service of the same name that it did not create (`refusing to reconcile service: ..., not owned by the cluster`). Delete such a Service before step 6; its port is closed until CNPG has made the new one.

Helm changes only objects it owns. When the cluster's objects already exist, step 6 fails with `invalid ownership metadata` for each of them, such as the `Cluster`, the `NetworkPolicy` or a `Certificate`. Either let Helm take them over: give each the label `app.kubernetes.io/managed-by=Helm` and the annotations `meta.helm.sh/release-name=pg` and `meta.helm.sh/release-namespace=databases`, after checking with `helm template` that the chart renders the same names (the replication `Certificate` is `<cluster>-replication`). Or copy the parts from the `helm template` output into the existing manifests by hand.

## LoadBalancers

k3s servicelb opens each LoadBalancer's port on every node:

- **rw, 5432:** every node forwards it to the primary.
- **read, `readLoadBalancer.port`:** with `selectorType: r` and `externalTrafficPolicy: Local`, a node forwards it only to the instance on that node, primary or replica, and only while that instance is ready. A node without a ready instance refuses the port, so a client moves on to the next node at once. Connections keep the client's address, which the policy admits as outside on 5432; the read LoadBalancer needs no entry of its own.

Both set `allocateLoadBalancerNodePorts: false`, so neither opens a NodePort. The read LoadBalancer still has a `healthCheckNodePort`: Kubernetes gives one to every LoadBalancer with traffic policy Local. It answers over HTTP how many ready instances the node has and does not lead to PostgreSQL.

A NodePort that a Service had before keeps working after a chart upgrade: Kubernetes keeps a NodePort it has allocated, and CNPG does not remove it. Remove it once by hand, then check that `kubectl get svc -n databases` shows no second port for the Service:

```bash
kubectl patch service pg-rw-lb -n databases --type=json -p '[{"op":"remove","path":"/spec/ports/0/nodePort"}]'
```

### Clients on the read port

A client lists every node in the host field with the read port and a short `connect_timeout`. pgx tries the hosts in order and takes the first that lets it in. For example:

```
host=node1.example.com,node2.example.com,node3.example.com port=5433 dbname=orders user=orders
sslmode=verify-ca sslrootcert=ca.crt sslcert=orders-app.crt sslkey=orders-app.key connect_timeout=2
```

`verify-ca`, because the server certificate names `replication.dnsNames`, not the nodes. With the node names in `replication.dnsNames`, use `verify-full`.

Reads on the read port can be slightly behind the primary: a commit waits for one replica, and the other replica stays ready while it is less than 16Mi behind.

Measured on a three-node k3s cluster with the example `desired.yaml`, CNPG 1.30.1 and pgx 5.11, with a new connection and one `SELECT` every 0.25 s and the stopped node listed first:

| Event | Reads | Writes on 5432 |
|---|---|---|
| A replica's node stops for 120 s | 0 of 960 failed. Each new connection took about 2 s while the node was down: the stopped node does not refuse, so pgx waits for `connect_timeout` before it moves on. The replica served reads again 26 s after its node started. | 0 of 960 failed. |
| A replica is not ready, its node runs | Its node refuses at once, and pgx moves on. 0 of 358 failed, typically 20 ms per connection. | Not measured. |
| The primary's node stops for 120 s | Worked for the first 26 s, then failed on every node until 24 s after the node started again: without a primary, the replicas stop streaming and fail the readiness check. | Failed from the stop until 23 s after the node started again. CNPG promoted no replica. |

An open connection ends when the node it entered through stops, and when its instance is promoted.

## Changes later

- A new database is one more entry under `databases` and a `helm upgrade`.
- A new node needs a `helm upgrade` too: the NetworkPolicy lists every node's pod range and tunnel address. Until then `evidence.sh` cannot name the `outside` source.
- A second database namespace needs both RoleBindings there and an entry in `WATCH_NAMESPACE`, which restarts the operator.

## Restore into a new cluster

The same chart restores from the barman-cloud backups instead of running initdb. Use a new cluster name, so that its WAL archive goes to its own folder:

```bash
helm install pg-restore samples/chart -n databases -f desired.yaml \
  --set cluster.name=pg-restore --set recovery.enabled=true --set recovery.sourceCluster=pg \
  --set rwLoadBalancer.name=pg-restore-rw-lb --set readLoadBalancer=null
```

The restore gets its own rw LoadBalancer and no read LoadBalancer: CNPG refuses a Service that another cluster owns. While the old cluster holds 5432, the new LoadBalancer's svclb pods stay Pending, so check the restore through its pods or its `pg-restore-rw` Service inside the cluster.

`bootstrap.recovery` gets the same `database`, `owner` and `secret` fields as `initdb`, so CNPG creates no `app` either. A restore still copies what the backup holds: a backup taken before `app` was removed brings the `app` database and role back. After such a restore, run steps 3 and 4 of the next section on the new cluster.

## Remove app from a cluster bootstrapped with the defaults

A cluster bootstrapped with CNPG's defaults has an `app` database, an `app` role and a `<cluster>-app` Secret. Do these steps in this order: dropping `app` before step 1 breaks the instance manager's reconcile and the metrics.

1. Change the three bootstrap fields on the running `Cluster`. The CNPG webhook accepts this after bootstrap. Use the section the cluster was bootstrapped with:
   ```yaml
   bootstrap:
     initdb:
       database: postgres
       owner: postgres
       secret:
         name: <cluster>-bootstrap
   ```
   Apply the `<cluster>-bootstrap` Secret from `templates/bootstrap-secret.yaml` at the same time (username `postgres`, empty password). Keep it: CNPG writes its empty password onto `postgres`, which PostgreSQL stores as no password.
2. Delete the old Secret. The operator no longer recreates it:
   ```bash
   kubectl delete secret <cluster>-app -n <namespace>
   ```
3. Drop the database and the role as `postgres` over `kubectl exec`:
   ```bash
   kubectl exec -n <namespace> <primary pod> -c postgres -- psql -c 'DROP DATABASE app' -c 'DROP ROLE app'
   ```
   If `DROP ROLE` reports objects or privileges in other databases, first run `REASSIGN OWNED BY app TO postgres; DROP OWNED BY app;` in each of them.
4. Check: `kubectl get secret <cluster>-app -n <namespace>` reports NotFound, and `select rolname from pg_roles where rolname = 'app'` and `select datname from pg_database where datname = 'app'` return no rows.

## RBAC on chart upgrades

The operator and plugin charts do not render RBAC here, so a new chart version can need a rule that the RBAC files lack. It then shows as `forbidden` in the operator or plugin log. Before each chart upgrade, render the RBAC of the old and the new version and compare. To work from `.tgz` files, give their paths in place of the chart name and `--repo`.

```bash
OLD=0.29.1 NEW=<new version>
for v in "$OLD" "$NEW"; do
  helm template cnpg cloudnative-pg --repo https://cloudnative-pg.github.io/charts --version "$v" \
    -n cnpg-system --set config.clusterWide=false --show-only templates/rbac.yaml >"cnpg-rbac-$v.yaml"
done
diff -I helm.sh/chart: -I app.kubernetes.io/version: "cnpg-rbac-$OLD.yaml" "cnpg-rbac-$NEW.yaml"

OLD=0.8.1 NEW=<new version>
for v in "$OLD" "$NEW"; do
  helm template barman-cloud plugin-barman-cloud --repo https://cloudnative-pg.github.io/charts --version "$v" \
    -n cnpg-system --show-only templates/rbac.yaml --show-only templates/additional-rbac/leader_election.yaml >"barman-rbac-$v.yaml"
done
diff -I helm.sh/chart: -I app.kubernetes.io/version: "barman-rbac-$OLD.yaml" "barman-rbac-$NEW.yaml"
```

No output means no RBAC change; the two `-I` options hide the version labels. Where a changed rule goes:

- Operator: the chart's ClusterRole `cnpg-cloudnative-pg` maps to `cnpg-operator-cluster`, its Role `cnpg-cloudnative-pg` to `cnpg-operator-namespaced`. At 0.29.1 both match the chart rule for rule.
- Plugin: the chart's ClusterRole `barman-cloud-plugin-barman-cloud` maps to `barman-cloud-namespaced`. At 0.8.1 the only difference is that Secrets lose `create` and `delete`; keep that cut. A resource the plugin watches at cluster scope also needs `list,watch` in `barman-cloud-cluster`.
- Plugin leader election: the chart renders this Role and RoleBinding even with RBAC off, so they are not in the RBAC file. They give only leader election rights in `cnpg-system`.
