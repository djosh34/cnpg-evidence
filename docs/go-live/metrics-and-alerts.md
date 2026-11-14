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

## Alerts

| Alert | Expression | Severity | Why |
|---|---|---|---|
| A k3s CA ends within a year | `k3s:certificate_expiration_timestamp_seconds - time() < 365 * 86400` | warning | Rotating a CA (`k3s certificate rotate-ca`) needs planning; k3s itself warns from 365 days |
| A k3s CA ends within 30 days | `… < 30 * 86400` | critical | |
| A k3s certificate ends within 30 days | `min by (node, subject) (k3s_certificate_expiration_seconds{usages!="CertSign"}) < 30 * 86400` | warning | That node's k3s has not restarted for about 11 months; restarting k3s there renews it |
| A k3s certificate ends within 7 days | `… < 7 * 86400` | critical | |
| The k3s certificate metric is missing | `absent(k3s_certificate_expiration_seconds{subject=~"CN=etcd-server-ca@.*"})`, for 1 h | warning | Otherwise every alert above goes silent |
| A cert-manager certificate ends within 14 days | `(certmanager_certificate_expiration_timestamp_seconds > 0) - time() < 14 * 86400` | warning | Renewal starts at two thirds of the lifetime, so this means it has failed for weeks |
| A cert-manager certificate ends within 3 days | `… < 3 * 86400` | critical | |
| A cert-manager certificate is not ready | `certmanager_certificate_ready_status{condition="False"} == 1`, for 1 h | warning | Issuance or renewal fails now, before the expiry alerts |
| A data volume is 70 % full | `kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.7`, for 5 min | warning | |
| A data volume is 80 % full | `… > 0.8`, for 5 min | critical | The kubelet evicts pods from about 85 % on k3s |

The expiry alerts can wait 15 minutes (`for: 15m`): the values change slowly. The disk alerts in the samples, with the rest of the sample rules, are in [`samples/monitoring/rules.yaml`](../../samples/monitoring/rules.yaml).
