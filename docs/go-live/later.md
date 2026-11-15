# Later

What the samples do that can wait until after go-live. [samples.md](../samples.md#what-the-samples-change-and-why) gives the reason for each. The variant [`every-item`](../../variants/every-item) of the scenarios applies the base, the first list and every item below, except two:

- Its audit log stays on the node: the scenarios have no log store to ship it to.
- The plugin's RBAC is not cut to its namespaces yet: the plugin can still list and watch ObjectStores, Roles and RoleBindings in every namespace. The plugin's `WATCH_NAMESPACE` was left out of the variant because no run had tested it; a later change adds it and runs it.

**Cluster**
- **Metrics over TLS** (`monitoring.tls.enabled: true`). A change rolls every instance, and the collectors must scrape with `https`.
- **`allocateLoadBalancerNodePorts: false`** on the rw LoadBalancer, so 5432 is the only port it opens on the nodes.
- **The monitoring queries in a Secret** (`customQueriesSecret`) and `metricsQueriesTTL: 0s`. Only the metrics improve: with a ConfigMap, the exporters lose their query metrics while a lost pod is being deleted.

**Kubernetes and k3s**
- **The operator's and the plugin's RBAC cut to their namespaces**, with `WATCH_NAMESPACE`. Every chart upgrade then needs an RBAC comparison ([samples.md](../samples.md#rbac-on-chart-upgrades)).
- **cert-manager, Traefik and metrics-server on every node.** Failover does not use them ([samples.md](../samples.md#one-pod-per-node)).
- **plugin-barman-cloud 0.16.0 or later** (chart 0.9.0), in which every plugin pod serves, not only the leader.
- **An API audit policy** for `pods/exec`, `pods/attach` and `secrets` in the database namespace, shipped off the node.
