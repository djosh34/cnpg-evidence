# Monitoring

Alert rules, an Alertmanager configuration and a Grafana dashboard for the sample's cluster, in `samples/monitoring/`, and the OTel collectors that send the metrics, in [`samples/charts/cnpg-opentelemetry-collector/`](../samples/charts/cnpg-opentelemetry-collector). Only the collectors run in the Kubernetes cluster. Outside it, an upstream OTel service receives the metrics, a rule evaluator reads them, Alertmanager sends the notifications, and Grafana shows the dashboard. The [bench](bench.md#monitoring) runs it this way.

## Files

| File | What it is |
|---|---|
| [`rules.yaml`](../samples/monitoring/rules.yaml) | The eleven alerts as Prometheus rules, and the databases they watch |
| [`rules.test.yaml`](../samples/monitoring/rules.test.yaml) | Unit tests of the rules, for `promtool test rules` |
| [`alertmanager.yaml`](../samples/monitoring/alertmanager.yaml) | The route and inhibition rules for those alerts |
| [`dashboard.json`](../samples/monitoring/dashboard.json) | The Grafana dashboard (see [Dashboard](#dashboard)) |
| [`dashboard.py`](../samples/monitoring/dashboard.py) | Writes `dashboard.json` |
| [`check.sh`](../samples/monitoring/check.sh) | Checks the rules and the Alertmanager configuration with `promtool` and `amtool`, runs the unit tests, and checks that `dashboard.json` is up to date and that its Healthy tile and red tiles follow the firing critical alerts |

## Set up

1. In `rules.yaml`, set the namespace and cluster name in the `cnpg_sample:database` rule, one rule per CNPG cluster. Every alert covers only the clusters listed there. The thresholds are in the expressions of the alerts, each in one place.
2. Load `rules.yaml` into the rule evaluator: Prometheus (`rule_files:`) or the Mimir ruler (`mimirtool rules load samples/monitoring/rules.yaml --address=<Mimir URL> --id=<tenant>`). The evaluator sends firing alerts to Alertmanager. Alertmanager evaluates no rules; it only groups, mutes and sends them. The group `cnpg-sample-writes` sets its own interval of 5 s, so `CNPGWritesBlocked` sees a wait of 10 s; scrape the exporter every 5 s too (see below).
3. Copy the route under `routes:` and the `inhibit_rules` of `alertmanager.yaml` into the Alertmanager configuration, and set the receiver.
4. Run `bash samples/monitoring/check.sh` after a change. It needs docker, python3 and [yq](https://github.com/mikefarah/yq).

## Scrape targets and labels

The rules read three sources, under the metric names the exporters give them. A pipeline that renames metrics on the way into the evaluator, for example by adding `_total` or unit suffixes, needs the names in the rules changed to match.

| Source | Metrics the rules read | Labels |
|---|---|---|
| CNPG's metrics exporter, `https://<pod address>:9187/metrics` on every instance pod | `cnpg_*`, and `barman_cloud_cloudnative_pg_io_*`, which the barman-cloud plugin reports through it | The scrape adds `namespace`, `pod`, `cluster` (the pod label `cnpg.io/cluster`) and `node` |
| The kubelet's `/metrics` on every node | `kubelet_volume_stats_used_bytes`, `kubelet_volume_stats_capacity_bytes` | Their own `namespace` and `persistentvolumeclaim`; the scrape adds `node`, the node's name |
| cert-manager's controller, port 9402 | `certmanager_certificate_expiration_timestamp_seconds` | Their own `namespace` and `name` of the Certificate, kept as they are (`honor_labels: true`) |

`cluster` is the CNPG cluster's name; it names the database in every rule. The rules need no other source.

For the exporter, a Prometheus scrape that adds the four labels, every 5 s: `CNPGWritesBlocked` must see a wait of 10 s, and the chart sets `metricsQueriesTTL: 0s`, so each scrape runs the queries anew. The `node` label names each instance by its node on the dashboard. The OTel collector's `prometheus` receiver takes the same `scrape_configs`. The chart's NetworkPolicy admits 9187 only from the OTel namespace. The scrape checks the server certificate with the CA that issued it and one of the names in it, `replication.dnsNames`; a company CA that issues only approved names, such as the node names, issues no `pg-rw`.

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

## Collectors

[`cnpg-opentelemetry-collector`](../samples/charts/cnpg-opentelemetry-collector) is a values chart of the upstream `opentelemetry-collector` chart with two collectors in the namespace `otel`:

| Collector | Kind | Scrapes |
|---|---|---|
| `otel-agent` | DaemonSet, one per node | The CNPG exporters of the instances on its node every 5 s, as above; its node's kubelet `/metrics` and `/metrics/cadvisor` |
| `otel-cluster` | Deployment, one replica | cert-manager's controllers |

Each scrape is done once. Both send OTLP over gRPC with mTLS to one upstream URL, `otel.example.test:4317`, with a client certificate from the company CA (`templates/certificate.yaml`) and the CA from the Secret `company-ca`. The upstream service hands the metrics to the rule evaluator by remote write with `translation_strategy: UnderscoreEscapingWithoutSuffixes`, which keeps every metric name: with suffixes, `cnpg_pg_stat_database_xact_commit` would arrive as `cnpg_pg_stat_database_xact_commit_total`. Every label of the scrape arrives as it is.

A collector that is lost with its node sends no stale marker, so the evaluator keeps its last samples for its lookback, 5 minutes in Prometheus: a lost primary would still count as the primary. The rules therefore count an instance only while its metrics arrive, `cnpg_sample:instance_reports`: its newest `cnpg_collector_up` is at most 30 s older than the newest of its cluster. An instance whose collector is lost counts as reporting nothing 30 s later, so `CNPGReplicaDown` fires about 5.5 minutes after its node is lost, also for the primary, and a lost primary no longer hides `CNPGDatabaseDown`. When every collector stops, the newest samples are all old, and the instances count until the lookback ends.

## Alerts

| Alert | Severity | Fires when | For |
|---|---|---|---|
| `CNPGDatabaseDown` | critical | No instance reports a running primary, and none answers without saying whether it is one: PostgreSQL is down or fenced on every instance, no replica has been promoted yet, or the primary's metrics do not arrive | 3 min |
| `CNPGReplicaDown` | critical | An instance seen in the last day, other than the primary, is not in the primary's `pg_stat_replication`, or its metrics do not arrive: the instance is down, does not stream, its scrape fails, or its collector is lost | 5 min |
| `CNPGReplicaLag` | critical | A replica is more than 15 s behind (see [Replica lag](#replica-lag)) | 2 min |
| `CNPGWritesBlocked` | critical | Sessions on the primary wait for a synchronous standby to confirm their commit (see [Writes blocked](#writes-blocked)) | 10 s |
| `CNPGBackupFailing` | critical | The last backup is older than 26 h or there is none, the last backup failed, or WAL archiving fails on the primary | 10 min |
| `CNPGDataDiskFull` | warning, critical | The disk an instance keeps its data on is more than 70 % or 80 % used (see [Data disks](#data-disks)) | 5 min |
| `CNPGCertificateExpiring` | warning, critical | The chart's server or replication certificate (`<cluster>-server`, `<cluster>-replication`) expires within 14 or 3 days | 15 min |
| `CNPGConnectionsHigh` | critical | An instance has more than 90 % of `max_connections` open | 5 min |
| `CNPGTransactionIDWraparound` | critical | The oldest transaction ID of a database is more than 1 billion transactions old; PostgreSQL stops at about 2.1 billion | 15 min |
| `CNPGComplianceViolation` | critical | A check of the [compliance metric](samples.md#compliance-metric) counts a violation | 1 min |
| `CNPGMetricsMissing` | critical | An instance that answers reports fewer than the four compliance checks: the compliance query fails, for example without its grants, or the exporter returns none of its query metrics | 10 min |

The 26 h backup age fits a daily backup; change it to the schedule. `CNPGBackupFailing` and the dashboard's **Last backup** take the newest backup the plugin reported in the last 2 h (see [What the rules do not see](#what-the-rules-do-not-see)). CPU, memory, deadlocks, long transactions and primary changes are on the dashboard only.

The dashboard's Healthy tile counts the critical alerts that fire. `check.sh` tests that on every case of `rules.test.yaml`.

### Replica lag

The chart's query on each replica reports `cnpg_replica_lag_seconds`: 0 when the replica has replayed all the WAL its primary last reported (`latest_end_lsn` of `pg_stat_wal_receiver` is not past `pg_last_wal_replay_lsn()`), otherwise the age of the last transaction it replayed. The primary reports none. Every commit waits for one replica only, so the other one can fall behind while writes go on, and it still serves reads on its node's read port. `CNPGReplicaLag` fires when a replica stays more than 15 s behind for 2 minutes.

A replica whose WAL receiver does not run, for example while there is no primary or while it catches up from the object store, reports the age of its last transaction. `CNPGReplicaDown` mutes `CNPGReplicaLag` of a replica that does not stream, and `CNPGDatabaseDown` mutes it once no primary has run for 3 minutes.

### Writes blocked

The chart's query reports `cnpg_sync_replication_waiting`: the sessions that wait right now for a standby to confirm their commit (`wait_event = 'SyncRep'` in `pg_stat_activity`). Every commit waits for one other instance, so while no standby confirms, every write waits; reads still work. `CNPGWritesBlocked` fires when sessions wait at every scrape for 10 s. A long statement does not count: a session counts only while its commit waits, so a commit that waits a moment after a long statement does not fire it.

### Data disks

`cnpg_sample:data_disk_used_ratio` is the used share of the disk each instance keeps its data on, from the kubelet's stats of its data volume (the PVC named like the pod), with the node's name. For a `local-path` volume the kubelet reports the whole filesystem of the node the volume is on, so it is that disk that fills. `CNPGDataDiskFull` warns at 70 % and is critical at 80 %: on k3s the kubelet starts to evict pods from a node at about 85 %, as by default it keeps 10 % of the node's filesystem and 15 % of the image filesystem free, and both are that same disk. The PVC's requested size is not shown, as `local-path` does not enforce it.

## Dashboard

`dashboard.json` is a Grafana dashboard (Grafana 12 or later) for one CNPG cluster: a status strip, the state of each instance over time, then rows for workload, replication, rule checks and nodes. Backups, WAL and vacuum are in a collapsed row. Instances are named by the node they run on; purple marks the primary.

To import it, in Grafana open *Dashboards*, *New*, *Import*, and upload `dashboard.json`. It expects a Prometheus-type data source, such as Prometheus or Mimir, that holds the metrics of the rules' sources and what the rule evaluator writes: the series `rules.yaml` records (`cnpg_sample:*`) and `ALERTS`, the alerts that are pending or firing. Prometheus and the Mimir ruler write both into the data they evaluate. Pick the data source in the *Data source* variable at the top. The *Namespace* and *Cluster* variables select the CNPG cluster by the `namespace` and `cluster` labels.

The dashboard reads one more source:

| Source | Metrics the dashboard reads | Labels |
|---|---|---|
| The kubelet's `/metrics/cadvisor` on every node | `container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`, `machine_cpu_cores`, `machine_memory_bytes`, for the CPU and memory of each node | Their own `id`; the scrape adds `node` |

Red means that a critical alert fires, nothing else; orange that a value passed a warning threshold.

- **Healthy** is the number of critical alerts that fire for the database. An alert fires only once its condition has held for its waiting time, so Healthy stays at Yes while an alert is pending.
- **Instances** shows each instance by its node: primary, replica, not streaming, PostgreSQL down or fenced. In red, *Down* while `CNPGReplicaDown` fires for it, also when its node is lost and its metrics are gone, and *Writes blocked* while `CNPGWritesBlocked` fires. An instance with no metrics shows only while `CNPGReplicaDown` fires for it.
- **Writes blocked** is the number of sessions that wait right now for a synchronous standby, `cnpg_sync_replication_waiting`: orange while any wait, red only while `CNPGWritesBlocked` fires.
- **Replica lag**, **Rule checks**, **Certificates**, **Data disks** and, in the collapsed row, **Last backup** show their value, and turn red only while their critical alert fires: `CNPGReplicaLag`; `CNPGComplianceViolation` or `CNPGMetricsMissing`; `CNPGCertificateExpiring`; `CNPGDataDiskFull`; `CNPGBackupFailing`. Certificates are the chart's server and replication certificates, the two the alert watches. Data disks is the fullest of the instances' data disks.
- Panels that read metrics only some setups report stay empty without them: the backup panel without the barman-cloud plugin, the rule checks without the [compliance metric](samples.md#compliance-metric).

`check.sh` checks, at every input step of every case of `rules.test.yaml`, also while an alert is pending, that Healthy equals the number of firing critical alerts and that each red tile is red exactly while one of its alerts fires. Change a panel in `dashboard.py`, then run `python3 samples/monitoring/dashboard.py`.

## One notification per problem

- An alert about the whole database, such as `CNPGDatabaseDown` or `CNPGBackupFailing`, is one alert per database, not one per pod. Alerts that name a pod, certificate or check carry that name.
- Alertmanager groups by `namespace`, `cluster` and alert name: one notification when the group fires and one when it resolves. A pod that joins a firing group, or a warning that turns critical, sends an update. While the group fires, a reminder comes every 4 h.
- `CNPGDatabaseDown` mutes the replica, lag, backup and missing-metrics alerts of the same database.
- `CNPGReplicaDown` mutes `CNPGMetricsMissing` and `CNPGReplicaLag` of the same instance.
- A critical alert mutes the warning of the same alert and instance or certificate.

Alertmanager does not promise exactly one notification. After a restart that lost its stored state, or between Alertmanager peers that cannot reach each other, a notification can come again.

## What the rules do not see

- `CNPGDatabaseDown` also fires when PostgreSQL runs but the primary's metrics stop arriving. The rules cannot tell the two apart.
- The exporter answers without the metrics of its queries when the `Cluster` changes many times a second: each change gives every instance a new, empty set of query results. CNPG 1.30.1 makes such changes itself while a lost pod is marked for deletion, unless the `Cluster` lists a Secret in `monitoring.customQueriesSecret`, as the chart does. `CNPGMetricsMissing` fires for an instance whose query metrics stay away for 10 minutes.
- `CNPGReplicaDown` compares the instances seen in the last day with the primary's `pg_stat_replication`, in `cnpg_pg_stat_replication_*`, where CNPG names each replica by its pod in `application_name`. While no instance reports itself as the primary, it sees only instances whose metrics stopped. An instance removed on purpose keeps the alert for a day, until it drops out of the rule's one-day window; silence it in Alertmanager.
- `CNPGCertificateExpiring` covers only the chart's two Certificates, as cert-manager reports them. Client certificates and the CA in `caSecret` belong to no database in the rules: a cert-manager Certificate for one needs its own rule on `certmanager_certificate_expiration_timestamp_seconds`, and one made without cert-manager has no expiry metric at all.
- Right after a node is lost, the scrapes of the other instances' exporters can take longer than 5 s and fail, for up to about 40 s in the sample's tests. The cause is not known. Their metrics are missing for that time; no alert waits less than 3 minutes for missing metrics.
- On a cluster without writes, a replica that has replayed everything reports the age of its last transaction as soon as its WAL receiver stops. A failover that takes longer than 2 minutes then fires `CNPGReplicaLag` for the replicas, before `CNPGDatabaseDown` mutes it at 3 minutes. Failovers in the sample's tests took less than 2 minutes, except with a broken object store.
- The barman-cloud plugin can report its last backup as 0 for a while when the backup is still in the store. The primary's plugin sidecar lists the store's backups when it starts and every `retentionPolicyIntervalSeconds` (30 min by default). If the store does not answer every read of that list, Barman can return a list without the backup and still succeed. The plugin then deletes the `Backup` object of each backup missing from the list, and reports 0. By the plugin's code, a later list that has the backup again sets the value back; the sample's tests did not run that long. The backup in the store is not touched, but its `Backup` object stays deleted. In the sample's tests this happened when the primary came back after its node and another node were lost. `CNPGBackupFailing` and **Last backup** use the newest value of the last 2 h, so such a 0 is ignored for 2 h. A 0 that lasts longer counts as no backup, and the alert fires 10 minutes later.
- `CNPGDataDiskFull` needs a storage driver that reports kubelet volume stats, as `local-path` does. It sees only the data volume; a separate WAL or tablespace volume needs its own rule.
