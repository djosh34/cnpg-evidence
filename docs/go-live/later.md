# Later

What the samples do that can wait until after go-live. [samples.md](../samples.md#what-the-samples-change-and-why) gives the reason for each.

**Cluster**
- **No `app` database, role or Secret.** Three `bootstrap.initdb` values and a placeholder Secret when the cluster is created, so nothing is created and nothing has to be deleted; on a running cluster it is the [removal runbook](../samples.md#remove-app-from-a-cluster-bootstrapped-with-the-defaults).
- **Metrics over TLS** (`monitoring.tls.enabled: true`). A change rolls every instance, and the collectors must scrape with `https`.
- **`switchoverDelay: 30`.** With a hanging bucket, a switchover takes about 10 minutes instead of 16.
- **`primaryUpdateMethod` back to `switchover`**, once a CNPG release with [cloudnative-pg#11677](https://github.com/cloudnative-pg/cloudnative-pg/pull/11677) runs (1.31.0 or later).
- **`allocateLoadBalancerNodePorts: false`** on the rw LoadBalancer, so 5432 is the only port it opens on the nodes.
- **The monitoring queries in a Secret** (`customQueriesSecret`) and `metricsQueriesTTL: 0s`. Only the metrics improve: with a ConfigMap, the exporters lose their query metrics while a lost pod is being deleted.

**Kubernetes and k3s**
- **The operator's and the plugin's RBAC cut to their namespaces**, with `WATCH_NAMESPACE`. Every chart upgrade then needs an RBAC comparison ([samples.md](../samples.md#rbac-on-chart-upgrades)).
- **cert-manager, Traefik and metrics-server on every node.** Failover does not use them ([samples.md](../samples.md#one-pod-per-node)).
- **plugin-barman-cloud 0.16.0 or later** (chart 0.9.0), in which every plugin pod serves, not only the leader.
- **An API audit policy** for `pods/exec`, `pods/attach` and `secrets` in the database namespace, shipped off the node.
