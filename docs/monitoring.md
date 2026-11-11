# Monitoring

Alert rules, an Alertmanager route and a Grafana dashboard for the sample's cluster are in [`samples/monitoring/`](../samples/monitoring). The OTel collectors that send the metrics are in [`samples/charts/cnpg-opentelemetry-collector/`](../samples/charts/cnpg-opentelemetry-collector). Only the collectors run in Kubernetes. Outside it, an OTel service receives the metrics, a rule evaluator reads them, Alertmanager sends the notifications and Grafana shows the dashboard. Every scenario runs it this way and checks that only the expected alerts fire.

| File | What |
|---|---|
| `rules.yaml` | The eleven alerts, and the clusters they watch |
| `rules.test.yaml` | Unit tests of the rules |
| `alertmanager.yaml` | The route and inhibition rules |
| `dashboard.json` | The dashboard, written by `dashboard.py` |
| `check.sh` | Checks all of the above with `promtool` and `amtool` |

## Set up

1. In `rules.yaml`, set the namespace and cluster name in the `cnpg_sample:database` rule, one rule per CNPG cluster. Every alert covers only those clusters.
2. Load `rules.yaml` into Prometheus (`rule_files:`) or the Mimir ruler (`mimirtool rules load samples/monitoring/rules.yaml --address=<Mimir URL> --id=<tenant>`).
3. Copy the route and the `inhibit_rules` of `alertmanager.yaml` into your Alertmanager configuration and set the receiver.
4. Install the collectors once the Secret `company-ca` with `ca.crt` is in `otel`, after replacing the scenario's names in its values:
   ```bash
   helm dependency build --skip-refresh samples/charts/cnpg-opentelemetry-collector
   helm upgrade --install otel samples/charts/cnpg-opentelemetry-collector -n otel
   ```
5. Import `dashboard.json` in Grafana 12 or later, under *Dashboards*, *New*, *Import*, and pick a Prometheus-type data source that also holds what the rules record and `ALERTS`.

After a change, run `bash samples/monitoring/check.sh`; it needs docker, python3 and yq. Change the dashboard in `dashboard.py`, then run `python3 samples/monitoring/dashboard.py`.

## What the rules read

Under the exporters' own metric names; a pipeline that renames metrics, for example with `_total`, needs the rules changed to match.

| Source | Metrics | Labels the scrape adds |
|---|---|---|
| CNPG's exporter, `https://<pod>:9187/metrics`, every 5 s | `cnpg_*`, and `barman_cloud_cloudnative_pg_io_*` from the plugin | `namespace`, `pod`, `cluster` (from `cnpg.io/cluster`), `node` |
| The kubelet's `/metrics` and `/metrics/cadvisor` | volume stats; CPU and memory for the dashboard | `node` |
| cert-manager's controller, port 9402 | `certmanager_certificate_expiration_timestamp_seconds` | none; keeps its own (`honor_labels: true`) |

The exporter scrape needs TLS with the server certificate's CA and one of its `dnsNames`, and runs every 5 s because `CNPGWritesBlocked` must see a 10 s wait. The collector chart does this; in plain Prometheus:

```yaml
scrape_configs:
  - job_name: cnpg
    scrape_interval: 5s
    scheme: https
    tls_config:
      ca_file: /etc/otel/company-ca/ca.crt  # the CA of the server certificate
      server_name: k3s-1.example.test       # one of its dnsNames
    kubernetes_sd_configs:
      - role: pod
        namespaces: {names: [databases]}
    relabel_configs:
      - {source_labels: [__meta_kubernetes_pod_label_cnpg_io_podRole], regex: instance, action: keep}
      - {source_labels: [__meta_kubernetes_pod_container_port_number], regex: "9187", action: keep}
      - {source_labels: [__meta_kubernetes_namespace], target_label: namespace}
      - {source_labels: [__meta_kubernetes_pod_name], target_label: pod}
      - {source_labels: [__meta_kubernetes_pod_label_cnpg_io_cluster], target_label: cluster}
      - {source_labels: [__meta_kubernetes_pod_node_name], target_label: node}
```

The chart runs `otel-agent`, a DaemonSet that scrapes the exporters and kubelet of its node, and `otel-cluster`, one pod that scrapes cert-manager. Both send OTLP with mTLS to `otel.example.test:4317`, which remote-writes to the evaluator with `translation_strategy: UnderscoreEscapingWithoutSuffixes`, so every name and label arrives as scraped. Run the collectors without `hostNetwork`.

A collector lost with its node sends no stale marker, so its last samples stay for the evaluator's 5 minute lookback. The rules therefore count an instance only while its newest `cnpg_collector_up` is at most 30 s older than its cluster's newest (`cnpg_sample:instance_reports`).

## Alerts

| Alert | Severity | Fires when | For |
|---|---|---|---|
| `CNPGDatabaseDown` | critical | No instance reports a running primary | 3 min |
| `CNPGReplicaDown` | critical | An instance seen in the last day, other than the primary, is not in the primary's `pg_stat_replication`, or its metrics stopped | 5 min |
| `CNPGReplicaLag` | critical | A replica's `cnpg_replica_lag_seconds` is above 15 s | 2 min |
| `CNPGWritesBlocked` | critical | Sessions on the primary wait for a standby to confirm their commit, at every scrape | 10 s |
| `CNPGBackupFailing` | critical | The newest backup of the last 2 h is older than 26 h, missing or failed, or WAL archiving fails | 10 min |
| `CNPGDataDiskFull` | warning, critical | An instance's data disk is over 70 % or 80 % used | 5 min |
| `CNPGCertificateExpiring` | warning, critical | The chart's server or replication certificate expires within 14 or 3 days | 15 min |
| `CNPGConnectionsHigh` | critical | An instance has over 90 % of `max_connections` open | 5 min |
| `CNPGTransactionIDWraparound` | critical | A database's oldest transaction ID is over 1 billion old | 15 min |
| `CNPGComplianceViolation` | critical | A check of the [compliance metric](samples.md#compliance-metric) counts a violation | 1 min |
| `CNPGMetricsMissing` | critical | An instance answers without the four compliance checks, for example without the query's grants | 10 min |

Every alert is one a person must act on. Thresholds are in the expressions, each in one place; change the 26 h backup age to fit your schedule.

- **Replica lag.** The chart's query reports 0 when the replica has replayed all the WAL its primary last reported, else the age of the last transaction it replayed. CNPG's `cnpg_pg_replication_lag` reports minutes on a caught-up replica after a restart. Only one replica confirms each commit, so the other can fall behind while it serves reads.
- **Writes blocked.** `cnpg_sync_replication_waiting` counts sessions whose commit waits right now, so a long statement does not count. The rule group runs every 5 s.
- **Data disks.** For `local-path` the kubelet reports the node's whole filesystem. On k3s the kubelet evicts pods at about 85 %, so 80 % comes first.
- **Backups.** The plugin can report its last backup as 0 for a while when its list of the store misses the backup, as after the primary's node and another node were lost. The rule takes the newest value of the last 2 h, so such a 0 counts only after 2 h.

**Notifications.** Alertmanager groups by `namespace`, `cluster` and alert name: one notification when a group fires, one when it resolves, a reminder every 4 h. `CNPGDatabaseDown` mutes the replica, lag, backup and missing-metrics alerts of its database, `CNPGReplicaDown` mutes the lag and missing metrics of its instance, and a critical alert mutes its own warning.

**Blind spots.**

- `CNPGDatabaseDown` cannot tell a down primary from one whose metrics stopped.
- An instance removed on purpose keeps `CNPGReplicaDown` for a day; silence it.
- `CNPGCertificateExpiring` covers only the chart's two certificates, not client certificates or the CAs in `caSecret`.
- Right after a node loss, the other exporters' scrapes can fail for up to about 40 s. The cause is not known; no alert waits less than 3 minutes for missing metrics.
- On a cluster without writes, a failover over 2 minutes fires `CNPGReplicaLag` before `CNPGDatabaseDown` mutes it.
- `CNPGDataDiskFull` sees only the data volume.

## Dashboard

One CNPG cluster: a status strip, each instance's state over time, then workload, replication, rule checks and nodes; backups, WAL and vacuum in a collapsed row. Instances are named by their node; purple marks the primary. The *Data source*, *Namespace* and *Cluster* variables pick the cluster.

Red means a critical alert fires, nothing else; orange that a value passed a warning threshold. **Healthy** counts the firing critical alerts, so it stays at Yes while an alert is pending. `check.sh` tests at every step of every rule test that Healthy and each red tile follow the alerts.
