# Gaps of first-list

The scenarios a run of `first-list` fails because it lacks something the samples have. Every other scenario passes. A red scenario not listed here, or a listed one that passes, is a defect ([e2e.md](../../docs/e2e.md#a-variants-gaps)).

| Scenario | Failed line | Gap | Closed by |
|---|---|---|---|
| `evidence-kubernetes` | `the kubernetes part of evidence.sh passes`: rule 6, the operator and the barman-cloud plugin can read Secrets in every namespace, through the charts' ClusterRoleBindings | The charts' cluster-wide RBAC | [The operator's and the plugin's RBAC cut to their namespaces](../../docs/go-live/later.md#the-operators-and-the-plugins-rbac-cut-to-their-namespaces) |
| `evidence-tls` | `the tls part of evidence.sh passes`: rule 1, metrics on 9187 do not use TLS, on every instance | Metrics in plain HTTP | [Metrics over TLS](../../docs/go-live/later.md#metrics-over-tls) |
