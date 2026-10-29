# Monitoring

Alert rules, an Alertmanager configuration and a Grafana dashboard for the sample's cluster, in `samples/monitoring/`. Nothing of it runs in the Kubernetes cluster: a rule evaluator outside it reads the metrics, Alertmanager sends the notifications, and Grafana shows the dashboard.

## Files

| File | What it is |
|---|---|
| [`rules.yaml`](../samples/monitoring/rules.yaml) | The ten alerts as Prometheus rules, and the databases they watch |
| [`rules.test.yaml`](../samples/monitoring/rules.test.yaml) | Unit tests of the rules, for `promtool test rules` |
| [`alertmanager.yaml`](../samples/monitoring/alertmanager.yaml) | The route and inhibition rules for those alerts |
| [`dashboard.json`](../samples/monitoring/dashboard.json) | The Grafana dashboard (see [Dashboard](#dashboard)) |
| [`dashboard.py`](../samples/monitoring/dashboard.py) | Writes `dashboard.json`; its Healthy tile from the critical alerts of `rules.yaml` |
| [`check.sh`](../samples/monitoring/check.sh) | Checks the rules and the Alertmanager configuration with `promtool` and `amtool`, runs the unit tests, and checks that `dashboard.json` is up to date and that its Healthy tile counts what the critical alerts see |

## Set up

1. In `rules.yaml`, set the namespace and cluster name in the `cnpg_sample:database` rule, one rule per CNPG cluster. Every alert covers only the clusters listed there. The thresholds are in the expressions of the alerts, each in one place.
2. Load `rules.yaml` into the rule evaluator: Prometheus (`rule_files:`) or the Mimir ruler (`mimirtool rules load samples/monitoring/rules.yaml --address=<Mimir URL> --id=<tenant>`). The evaluator sends firing alerts to Alertmanager. Alertmanager evaluates no rules; it only groups, mutes and sends them.
3. Copy the route under `routes:` and the `inhibit_rules` of `alertmanager.yaml` into the Alertmanager configuration, and set the receiver.
4. Run `bash samples/monitoring/check.sh` after a change. It needs docker, python3 and [yq](https://github.com/mikefarah/yq).

## Scrape targets and labels

The rules read three sources, under the metric names the exporters give them. A pipeline that renames metrics on the way into the evaluator, for example by adding `_total` or unit suffixes, needs the names in the rules changed to match.

| Source | Metrics the rules read | Labels |
|---|---|---|
| CNPG's metrics exporter, `https://<pod address>:9187/metrics` on every instance pod | `cnpg_*`, and `barman_cloud_cloudnative_pg_io_*`, which the barman-cloud plugin reports through it | The scrape adds `namespace`, `pod`, `cluster` (the pod label `cnpg.io/cluster`) and `node` |
| The kubelet's `/metrics` on every node | `kubelet_volume_stats_used_bytes`, `kubelet_volume_stats_capacity_bytes` | Their own `namespace` and `persistentvolumeclaim`; the scrape adds `node` |
| cert-manager's controller, port 9402 | `certmanager_certificate_expiration_timestamp_seconds` | Their own `namespace` and `name` of the Certificate, kept as they are (`honor_labels: true`) |

`cluster` is the CNPG cluster's name; it names the database in every rule. The rules need no other source.

For the exporter, a Prometheus scrape that adds the four labels. The OTel collector's `prometheus` receiver takes the same `scrape_configs`. The chart's NetworkPolicy admits 9187 only from the OTel namespace.

```yaml
scrape_configs:
  - job_name: cnpg
    scheme: https
    tls_config:
      ca_file: /etc/cnpg/ca.crt  # the CA of the server certificate
      server_name: pg-rw         # one of its dnsNames
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

## Alerts

| Alert | Severity | Fires when | For |
|---|---|---|---|
| `CNPGDatabaseDown` | critical | No instance reports a running primary, and none answers without saying whether it is one: PostgreSQL is down or fenced on every instance, no replica has been promoted yet, or the primary's metrics do not arrive | 3 min |
| `CNPGReplicaDown` | critical | The primary's replication slot for a replica is inactive, or an instance seen in the last day reports no metrics: the instance is down, does not stream, or its scrape fails | 5 min |
| `CNPGReplicaLag` | critical | A replica is more than 15 s behind (see [Replica lag](#replica-lag)) | 2 min |
| `CNPGBackupFailing` | critical | The last backup is older than 26 h or there is none, the last backup failed, or WAL archiving fails on the primary | 10 min |
| `CNPGVolumeFull` | warning, critical | A volume of an instance is more than 80 % or 90 % used | 5 min |
| `CNPGCertificateExpiring` | warning, critical | The chart's server or replication certificate (`<cluster>-server`, `<cluster>-replication`) expires within 14 or 3 days | 15 min |
| `CNPGConnectionsHigh` | critical | An instance has more than 90 % of `max_connections` open | 5 min |
| `CNPGTransactionIDWraparound` | critical | The oldest transaction ID of a database is more than 1 billion transactions old; PostgreSQL stops at about 2.1 billion | 15 min |
| `CNPGComplianceViolation` | critical | A check of the [compliance metric](samples.md#compliance-metric) counts a violation | 1 min |
| `CNPGMetricsMissing` | critical | An instance that answers reports fewer than the four compliance checks: the compliance query fails, for example without its grants, or the exporter returns none of its query metrics | 10 min |

The 26 h backup age fits a daily backup; change it to the schedule. CPU, memory, deadlocks, long transactions and primary changes are on the dashboard only.

The critical alerts are also the list of conditions for the dashboard's Healthy tile, which counts the same expressions with the same thresholds. `check.sh` tests that on every case of `rules.test.yaml`.

### Replica lag

Each replica reports `cnpg_pg_replication_lag`: the seconds since the last transaction it replayed, or 0 once it has replayed everything it received. Every commit waits for one replica only, so the other one can fall behind while writes go on, and it still serves reads on its node's read port. `CNPGReplicaLag` fires when a replica stays more than 15 s behind for 2 minutes.

A replica that receives nothing reports 0 too. `CNPGReplicaDown` covers that case.

## Dashboard

`dashboard.json` is a Grafana dashboard (Grafana 12 or later) for one CNPG cluster: a status strip, the state of each instance over time, then rows for workload, replication, certificates and rule checks, and nodes. Storage, backups, WAL and vacuum are in a collapsed row. Instances are named by the node they run on; purple marks the primary.

To import it, in Grafana open *Dashboards*, *New*, *Import*, and upload `dashboard.json`. It expects a Prometheus-type data source, such as Prometheus or Mimir, that holds the metrics below; pick it in the *Data source* variable at the top. The *Namespace* and *Cluster* variables select the CNPG cluster by the `namespace` and `cluster` labels.

The dashboard reads the sources of the rules, with the same labels, and two more:

| Source | Metrics the dashboard reads | Labels |
|---|---|---|
| The kubelet's `/metrics/cadvisor` on every node | `container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`, `container_fs_usage_bytes`, `container_fs_limit_bytes`, `machine_cpu_cores`, `machine_memory_bytes` | Their own `namespace`, `pod`, `container`, `id` and `device`; the scrape adds `node` |
| kube-state-metrics, with the `leases` resource | `kube_lease_owner`: which pod holds CNPG's primary lease, named after the cluster | Their own `namespace`, `lease`, `owner_kind` and `lease_holder`, kept as they are (`honor_labels: true`) |

The node of each instance comes from cAdvisor's series of its `postgres` container. A primary is an instance that is not in recovery and holds the lease; without lease data the dashboard decides by PostgreSQL alone.

- **Healthy** counts what the critical alerts see now, without their `for` time: `dashboard.py` writes their expressions into the tile, with the database set by the dashboard's variables. Change a critical alert in `rules.yaml`, then run `python3 samples/monitoring/dashboard.py`.
- **Writes blocked** is a primary with fewer standbys connected (`cnpg_pg_replication_streaming_replicas`) than the synchronous standbys it needs (`cnpg_collector_sync_replicas{value="expected"}`). A connected standby does not prove that it confirms commits.
- **Certificates** shows only certificates that cert-manager manages, every one in the Kubernetes cluster. A CA or client certificate supplied as a Secret without a cert-manager Certificate has no expiry metric and does not appear.
- Panels that read metrics only some setups report stay empty without them: the backup panel without the barman-cloud plugin, the rule checks without the [compliance metric](samples.md#compliance-metric).

## One notification per problem

- An alert about the whole database, such as `CNPGDatabaseDown` or `CNPGBackupFailing`, is one alert per database, not one per pod. Alerts that name a pod, volume, certificate or check carry that name.
- Alertmanager groups by `namespace`, `cluster` and alert name: one notification when the group fires and one when it resolves. A pod or volume that joins a firing group, or a warning that turns critical, sends an update. While the group fires, a reminder comes every 4 h.
- `CNPGDatabaseDown` mutes the replica, lag, backup and missing-metrics alerts of the same database.
- `CNPGReplicaDown` mutes `CNPGMetricsMissing` of the same database: while a node is lost, the other instances can stop reporting their query metrics (see below).
- A critical alert mutes the warning of the same alert and volume or certificate.

Alertmanager does not promise exactly one notification. After a restart that lost its stored state, or between Alertmanager peers that cannot reach each other, a notification can come again.

## What the rules do not see

- `CNPGDatabaseDown` also fires when PostgreSQL runs but the primary's metrics stop arriving. The rules cannot tell the two apart.
- The exporter can answer without the metrics of its queries. In tests with CNPG 1.30.1, every instance did so from about five minutes after a node was lost, when Kubernetes marked the pod on it for deletion, until the node returned; meanwhile the instances reconciled the `Cluster` many times a second. The rules then cannot tell which instance is the primary, nor read the replication slots. `CNPGReplicaDown` still fires for the lost instance, as its metrics are gone, and `CNPGMetricsMissing` for the others. If the lost node ran the primary and no replica has been promoted, `CNPGDatabaseDown` resolves once the replicas stop reporting their query metrics; only `CNPGReplicaDown` for the old primary is left.
- `CNPGReplicaDown` reads the primary's replication slots for its replicas, which CNPG keeps by default (`replicationSlots.highAvailability`). Without them it sees only instances whose metrics stopped. An instance removed on purpose keeps the alert for a day, until it drops out of the rule's one-day window; silence it in Alertmanager.
- `CNPGCertificateExpiring` covers only the chart's two Certificates, as cert-manager reports them. Client certificates and the CA in `caSecret` belong to no database in the rules: a cert-manager Certificate for one needs its own rule on `certmanager_certificate_expiration_timestamp_seconds`, and one made without cert-manager has no expiry metric at all.
- `CNPGVolumeFull` needs a storage driver that reports kubelet volume stats. Volumes of the `local-path` provisioner report the whole filesystem they are on.
