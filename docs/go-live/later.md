# Later

What the samples do that can wait until after go-live. Each link leads to the details: the problem, how behaviour changes, and what to change or check. The variant [`every-item`](../../variants/every-item) of the scenarios applies the base, the first list and every item below; its audit log stays on the node, since the scenarios have no log store to ship it to.

## Cluster

- **Metrics over TLS.** The exporters serve every instance's metrics in plain HTTP on 9187. [Below](#metrics-over-tls)
- **No NodePorts on the rw LoadBalancer.** Each node opens a second port to the primary besides 5432. [Below](#no-nodeports-on-the-rw-loadbalancer)
- **The monitoring queries in a Secret.** With a ConfigMap, every exporter answers without its query metrics while a lost pod is being deleted. [Below](#the-monitoring-queries-in-a-secret)

## Kubernetes and k3s

- **The operator's and the plugin's RBAC cut to their namespaces.** With the charts' RBAC, both read Secrets in every namespace. [Below](#the-operators-and-the-plugins-rbac-cut-to-their-namespaces)
- **cert-manager, Traefik and metrics-server on every node.** A lost node takes the only pod of each for at least 5 minutes. Failover does not use them. [Below](#cert-manager-traefik-and-metrics-server-on-every-node)
- **plugin-barman-cloud 0.16.0 or later.** Every plugin pod serves, not only the leader. [Below](#plugin-barman-cloud-0160-or-later)
- **An API audit log, rotated and shipped off the node.** Nothing records who opened a shell next to the data or read its Secrets. [Below](#an-api-audit-log-rotated-and-shipped-off-the-node)

## Metrics over TLS

**Problem.** Each instance serves its metrics on 9187 in plain HTTP. The NetworkPolicy admits only the collectors' namespace, but the metrics cross the node network unencrypted, and nothing proves to the collector which server answered.

**What changes.** The exporters serve TLS with the server certificate, and the collectors check it against the company CA. A change restarts every instance, one at a time.

**How.** On the `Cluster`:

```yaml
spec:
  monitoring:
    tls:
      enabled: true
```

In each collector's scrape job of the instances, as in [`every-item`'s collector values](../../variants/every-item/charts/cnpg-opentelemetry-collector/values.yaml): `scheme: https`, `tls_config.ca_file` with the company CA, and `tls_config.server_name` a name of the server certificate, since the collector scrapes by pod address. Change the collectors together with the `Cluster`, or their scrapes fail until both match. Check: the collectors' `up` of every instance is 1 after the change, and `evidence.sh --part tls` reports no "metrics on 9187 do not use TLS".

## No NodePorts on the rw LoadBalancer

**Problem.** A LoadBalancer Service also gets a NodePort, by default. k3s's servicelb then opens a port between 30000 and 32767 on every node that leads to the primary, next to 5432.

**What changes.** 5432 is the only port the rw LoadBalancer opens on the nodes.

**How.** In the `Cluster`'s rw LoadBalancer, as in [`every-item`'s cluster template](../../variants/every-item/charts/cnpg-cluster/templates/cluster.yaml):

```yaml
serviceTemplate:
  spec:
    type: LoadBalancer
    allocateLoadBalancerNodePorts: false
```

Kubernetes keeps the NodePorts it already gave an existing Service: remove the `nodePort` of each port too, or let CNPG recreate the Service. Check: `kubectl get service <name> -n <namespace> -o jsonpath='{.spec.ports[*].nodePort}'` prints nothing.

## The monitoring queries in a Secret

**Problem.** When the queries are in a ConfigMap, CNPG 1.30.1 rewrites the `Cluster` status many times a second while a lost pod is marked for deletion. Every instance's exporter then answers without its query metrics until the pod is gone ([samples.md](../samples.md#what-the-samples-change-and-why)).

**What changes.** With the same queries in a Secret, CNPG does not rewrite the status in that loop, and the exporters keep their query metrics.

**How.** Put the queries into a Secret under the same key, and on the `Cluster` name it in place of the ConfigMap, as in [`every-item`'s queries](../../variants/every-item/charts/cnpg-cluster/templates/queries.yaml):

```yaml
spec:
  monitoring:
    customQueriesSecret:
      - name: <cluster>-queries
        key: queries
```

Check: `kubectl get cluster <cluster> -n <namespace> -o jsonpath='{.spec.monitoring}'` names `customQueriesSecret` and no `customQueriesConfigMap`, and the compliance and lag metrics still arrive.

## The operator's and the plugin's RBAC cut to their namespaces

**Problem.** The charts give the CNPG operator and the barman-cloud plugin cluster-wide rights: both can read every Secret in the cluster, the operator can also exec into every pod, and the plugin can create and delete Secrets anywhere. Whoever takes over one of their pods gets all of that.

**What changes.** The operator has rights, and watches, only in its own namespace and the database namespaces; the plugin only in the database namespaces, besides its leader election in its own. Cluster-wide, the operator keeps only what is not in a namespace: nodes, its webhook configurations and the cluster image catalogs.

**How.** Turn the charts' RBAC off and bind the same rules per namespace, as [`every-item`'s operator chart](../../variants/every-item/charts/cnpg-cloudnative-pg) and [plugin chart](../../variants/every-item/charts/cnpg-plugin-barman-cloud) do:

- Operator: `rbac.create: false`, `config.clusterWide: true` (so the chart does not set its own `WATCH_NAMESPACE`), and `WATCH_NAMESPACE=cnpg-system,<database namespaces>` in `additionalEnv`. A ClusterRole with the namespaced rules, bound by a RoleBinding in each of those namespaces, and a ClusterRole with the cluster-scoped rules.
- Plugin, 0.16.0 or later: `rbac.create: false`, `WATCH_NAMESPACE=<database namespaces>` in `additionalEnv`, and a Role and RoleBinding with the chart's rules in each database namespace, Secrets cut to `get`, `list` and `watch`.

A new database namespace needs its entry in both lists and its bindings. Every chart upgrade then needs an RBAC comparison ([samples.md](../samples.md#rbac-on-chart-upgrades)); a missing rule shows as `forbidden` in the operator's or the plugin's log. Check: `kubectl auth can-i get secrets -n kube-system --as system:serviceaccount:cnpg-system:<service account>` answers `no` for both, and `evidence.sh --part kubernetes` passes rule 6.

## cert-manager, Traefik and metrics-server on every node

**Problem.** Kubernetes moves the pods of a lost node only after 5 minutes. With one pod each, a lost node can take cert-manager (no certificate issued or renewed, and its webhook refuses changes to cert-manager's objects), Traefik (no http-01 challenge answered, so no ACME order completes) or metrics-server (no `kubectl top`, no autoscaling). Failover does not use any of them.

**What changes.** One pod of each per node, as for the operator and the plugin ([failover.md](failover.md#the-plugin-and-the-operator-on-every-node)).

**How.** As [samples.md](../samples.md#one-pod-per-node) says and `every-item` does:

- cert-manager: in its chart's values, for the controller, the webhook and the CA injector, 3 replicas, required anti-affinity by host name and `maxSurge: 0` ([values](../../variants/every-item/charts/cnpg-cert-manager/values.yaml)).
- Traefik: `deployment.kind: DaemonSet` in a `HelmChartConfig` in `/var/lib/rancher/k3s/server/manifests/` of every server ([`traefik-config.yaml`](../../variants/every-item/k3s/manifests/traefik-config.yaml)).
- metrics-server: 3 replicas and required anti-affinity by host name, one `kubectl patch` ([`patches.yaml`](../../variants/every-item/k3s/patches.yaml)). k3s's manifest sets neither field, so the patch holds across k3s restarts.

Check: `kubectl get pods -n cert-manager -o wide` and `kubectl get pods -n kube-system -o wide` show one pod of each per node.

## plugin-barman-cloud 0.16.0 or later

**Problem.** Up to 0.15, only the plugin's leader pod serves CNPG's calls. When the leader's node is lost, no pod serves until another takes the lease, about 20 s, and CNPG does nothing for the cluster in that time ([failover.md](failover.md#the-plugin-and-the-operator-on-every-node)). It also cannot limit what it watches to some namespaces.

**What changes.** From 0.16.0 every plugin pod serves, so a lost pod leaves the others answering, and `WATCH_NAMESPACE` limits its watches ([above](#the-operators-and-the-plugins-rbac-cut-to-their-namespaces)). This comes from the plugin's changelog and code; the scenarios of `every-item` run it, with no measured difference in failover.

**How.** Upgrade the `plugin-barman-cloud` chart to 0.9.0 or later, when no failover is expected: the chart replaces all its pods at once. Compare its RBAC first ([samples.md](../samples.md#rbac-on-chart-upgrades)). Check: `kubectl get deployment -n cnpg-system -o wide` shows the plugin image `v0.16.0` or later.

## An API audit log, rotated and shipped off the node

**Problem.** Nothing records who opened a shell in an instance's pod, which reaches all its data, or who read a Secret of the database namespace.

**What changes.** Each API server logs these requests, without their bodies: `pods/exec`, `pods/attach` and `secrets` in the database namespace, and across all namespaces. Nothing else is logged. The log is rotated, so it never fills the node's disk, and a log collector ships it off the node, where whoever takes over a node cannot erase what was shipped.

**How.** The policy file [`audit-policy.yaml`](../../variants/every-item/k3s/audit-policy.yaml) on every server, and in each server's k3s config, as in [`every-item`'s](../../variants/every-item/k3s/config.yaml):

```yaml
kube-apiserver-arg:
  - audit-policy-file=/etc/rancher/k3s/audit-policy.yaml
  - audit-log-path=/var/lib/rancher/k3s/server/logs/audit.log
  - audit-log-maxsize=100     # MB per file
  - audit-log-maxbackup=5     # at most 5 old files: 600 MB in all
```

Then restart k3s on one server after another. Without `audit-log-maxsize` the log is never rotated and grows until the disk is full. Point the node's log collector at the log path; the scenarios have no log store, so `every-item`'s log stays on the node. Check: after a `kubectl exec` into an instance's pod, the newest line of `audit.log` on one server names it.
