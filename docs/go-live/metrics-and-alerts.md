# Metrics and alerts

**Problem.** Two failures build up over days and stop the database when nobody looks: a disk that fills, and a certificate that expires. When the replication certificate expires, replicas cannot log in and writes stop; when a k3s CA expires, the cluster stops.

**What changes.** Each certificate's end and each data volume's usage arrive as metrics, and alerts fire well before either matters. Nothing new runs in the cluster: k3s, cert-manager and the kubelet already export these, and the collectors only need to scrape them.

## Data disk

`kubelet_volume_stats_used_bytes` and `kubelet_volume_stats_capacity_bytes`, from the kubelet's `/metrics` on each node. For a local-path volume they report the filesystem that holds `/var/lib/rancher/k3s/storage`. They exist only for volumes of type `local` (see [the data disk](disk-and-bucket.md#the-data-disk)) and only while a pod mounts the volume.

A scrape job on the per-node collector, as in [`cnpg-opentelemetry-collector/values.yaml`](../../samples/charts/cnpg-opentelemetry-collector/values.yaml):

```yaml
- job_name: kubelet
  scrape_interval: 15s
  scheme: https
  authorization: {credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token}
  tls_config: {ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt}
  kubernetes_sd_configs:
    - role: node
      selectors: [{role: node, field: "metadata.name=${env:OTEL_K8S_NODE_NAME}"}]
  relabel_configs:
    - {source_labels: [__meta_kubernetes_node_name], target_label: node}
# its ClusterRole: {apiGroups: [""], resources: [nodes/metrics], verbs: [get]}
```

## k3s and etcd certificates

k3s exports `k3s_certificate_expiration_seconds{subject, usages}`, the seconds left, for every certificate it uses: its CAs (`usages="CertSign"`, subjects such as `CN=k3s-server-ca@<time>` and `CN=etcd-server-ca@<time>`), the etcd server, peer and client certificates, the API server's and every kubelet's. Both the kubelet's `/metrics` (the job above) and the API server's `/metrics` serve it, with no extra flag, since k3s v1.30.2. k3s refreshes the value every 30 minutes. Only servers report the CA and etcd series.

The end of each CA as unix time, one recording rule:

```yaml
- record: k3s:certificate_expiration_timestamp_seconds
  expr: time() + max by (subject, usages) (k3s_certificate_expiration_seconds{usages="CertSign"})
```

k3s's leaf certificates last a year and are renewed only when k3s starts within 120 days of their end. The CAs last 10 years and are never renewed by themselves.

## cert-manager certificates

`certmanager_certificate_expiration_timestamp_seconds{namespace, name, issuer_name}`, already unix time, and `certmanager_certificate_ready_status{condition}`, from cert-manager's controller on port 9402, for every `Certificate`. The chart marks its pods with `prometheus.io/*` annotations. A collector that discovers targets by `io.opentelemetry.discovery.metrics/*` annotations does not read those; give the pods those annotations through the chart's `podAnnotations`, or add a scrape job like the `cert-manager` job in the sample collector.

## The replica lag alert only for instances that report

**Problem.** A replica's lag comes from the chart's query on that replica: 0 when it has replayed all the WAL its primary reported, else the age of the last transaction it replayed. Just after a pause in writes, one sample can give the age of the last transaction before the pause: minutes, while the replica is less than a second behind. The next sample, 5 s later, is 0 again, and the alert waits 2 minutes, so on its own that sample pages nobody. But a replica lost with its node loses its collector too, which sends no stale marker, so its last sample stays with the evaluator for 5 minutes. In a scenario, the node of a replica was lost 8 s after the first writes following a pause: `CNPGReplicaLag` fired for 3 minutes on a lag of minutes that never was, before `CNPGReplicaDown`.

**What changes.** `CNPGReplicaLag` counts only instances whose metrics still arrive, as the other instance rules do. A lost replica drops out within 30 s, and `CNPGReplicaDown` reports it.

**How.** In the lag alert's expression, add the instance condition of the [sample rules](../../samples/monitoring/rules.yaml):

```yaml
- alert: CNPGReplicaLag
  expr: |
    max by (namespace, cluster, pod) (cnpg_replica_lag_seconds) > 15
    and on (namespace, cluster, pod) cnpg_sample:instance_reports
    and on (namespace, cluster) cnpg_sample:database
  for: 2m
```

`cnpg_sample:instance_reports` keeps an instance while its newest `cnpg_collector_up` is at most 30 s older than its cluster's newest, and at most 90 s old ([below](#an-instance-reports-only-while-its-metrics-are-fresh)). The unit test "a lost replica's last lag sample" in [`rules.test.yaml`](../../samples/monitoring/rules.test.yaml) checks it.

## metricsQueriesTTL: 0s

**Problem.** CNPG's exporter keeps the results of its monitoring queries for 30 s by default, and every scrape in that time gets the same values. During a failover the new primary's first commits wait a few seconds for a standby. When one query run catches them, the next scrapes repeat that count for up to 30 s. `CNPGWritesBlocked` fires after two such samples within 15 s and 10 s more, so it paged critical for the new primary 10 to 15 s after writes were back. In runs of the variant `first-list` without this setting, it fired after some failovers and not others; in a full run with it, it fired after none.

**What changes.** Every scrape runs the queries. A wait shows at the next scrape, and it is gone from the one after it ends. With the samples' 5 s scrape, the queries run every 5 s on each instance.

**How.** On the `Cluster`:

```yaml
spec:
  monitoring:
    metricsQueriesTTL: 0s
```

Check: `kubectl get cluster <cluster> -n <namespace> -o jsonpath='{.spec.monitoring.metricsQueriesTTL}'` gives `0s`.

## An instance reports only while its metrics are fresh

**Problem.** CNPG's exporter adds the backup plugin's metrics to every scrape, and the plugin reads its `ObjectStore` from the Kubernetes API, with no time limit. While the API does not answer, as with two of three nodes lost and so no etcd quorum, every scrape of the instance left waits and fails. No instance's metrics arrive. `cnpg_sample:instance_reports` compares each instance only with the newest of its cluster, so all of them, the lost primary too, count as reporting until their last samples leave the evaluator's 5 minute lookback. In a scenario with the primary's node and a replica's node lost, `CNPGDatabaseDown` had not fired after 5 minutes; it would have fired about 8 minutes in, not 4.

**What changes.** An instance counts as reporting only while its newest sample is also at most 90 s old. When every exporter stops, nothing reports after 90 s, and `CNPGDatabaseDown` fires 3 minutes later: its description already says it covers a primary whose metrics do not arrive. The up to about 40 s of failed scrapes seen right after one node is lost stay under 90 s and change nothing.

**How.** In the sample rules, the record:

```yaml
- record: cnpg_sample:instance_reports
  expr: |
    (
      max by (namespace, cluster, pod) (timestamp(cnpg_collector_up))
        > on (namespace, cluster) group_left ()
      max by (namespace, cluster) (timestamp(cnpg_collector_up)) - 30
    )
    > time() - 90
```

The unit test "every exporter stops" in [`rules.test.yaml`](../../samples/monitoring/rules.test.yaml) checks it, and the `database-down` scenario shows it on a cluster.

## Alerts

| Alert | Expression | Severity | Why |
|---|---|---|---|
| A k3s CA ends within a year | `k3s:certificate_expiration_timestamp_seconds - time() < 365 * 86400` | warning | Rotating a CA (`k3s certificate rotate-ca`) needs planning; k3s itself warns from 365 days |
| A k3s CA ends within 30 days | `… < 30 * 86400` | critical | |
| A k3s certificate ends within 30 days | `min by (node, subject) (k3s_certificate_expiration_seconds{usages!="CertSign"}) < 30 * 86400` | warning | k3s has not started on that node since the certificate came within 120 days of its end; restarting k3s there renews it |
| A k3s certificate ends within 7 days | `… < 7 * 86400` | critical | |
| The k3s certificate metric is missing | `absent(k3s_certificate_expiration_seconds{subject=~"CN=etcd-server-ca@.*"})`, for 1 h | warning | Otherwise every alert above goes silent |
| A cert-manager certificate ends within 14 days | `(certmanager_certificate_expiration_timestamp_seconds > 0) - time() < 14 * 86400` | warning | For 90-day certificates: renewal starts with a third of the lifetime left, so this means it has failed for weeks. For a shorter lifetime, use well under a third of it |
| A cert-manager certificate ends within 3 days | `… < 3 * 86400` | critical | |
| A cert-manager certificate is not ready | `certmanager_certificate_ready_status{condition="False"} == 1`, for 1 h | warning | The certificate is missing, expired or does not match its spec. A failed renewal while the old certificate is still valid can stay Ready, so the expiry alerts are still needed |
| A data volume is 70 % full | `kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.7`, for 5 min | warning | |
| A data volume is 80 % full | `… > 0.8`, for 5 min | critical | A full data disk stops PostgreSQL, and CNPG does not fail over |

The expiry alerts can wait 15 minutes (`for: 15m`): the values change slowly. The disk alerts in the samples, with the rest of the sample rules, are in [`samples/monitoring/rules.yaml`](../../samples/monitoring/rules.yaml).
