Feature: One scenario per alert
  Each scenario causes the real condition of one alert of
  monitoring/rules.yaml. It checks that the alert fires with its labels and
  that Alertmanager sends it, ends the condition, then checks that the alert
  resolves and that Alertmanager sends it resolved. Alertmanager sends a new
  group after 30 s, and a change of a group, a resolve included, at the
  group's next 5 minute interval. CNPGTransactionIDWraparound has no
  scenario; docs/monitoring.md says why.

  Background:
    Given the cluster is healthy

  @database-down
  Scenario: CNPGDatabaseDown: two of three nodes are lost for 5 minutes
    One etcd member of three leaves no Kubernetes API, so nothing is
    promoted. Replica 2 serves reads on, but its exporter waits on the backup
    plugin's metrics, which read the API, so no instance reports after 90 s.
    The nodes start once Alertmanager sent the alert, at least 5 minutes
    after the kill. Writes stop until the primary is back. In the samples the
    client reads on through replica 2; in a variant run, reading takes the
    limit of writing. No instance reports for about 5 minutes, so
    CNPGReplicaDown can fire. Once the nodes start, replica 2 reports again
    before it streams from the primary, with the age of its last replayed
    transaction as its lag, so CNPGReplicaLag can fire for it.

    When the primary's node and replica 1's node are killed
    Then CNPGDatabaseDown critical fires for the cluster < 420 s after the kill
    And Alertmanager sends CNPGDatabaseDown critical for the cluster < 60 s
    When 300 s pass after the kill
    And the nodes start
    Then CNPGDatabaseDown resolves for the cluster < 300 s
    And Alertmanager sends the resolved CNPGDatabaseDown critical for the cluster < 360 s
    And the cluster is healthy < 600 s
    And CNPGReplicaLag may fire for replica 2
    And CNPGReplicaDown may fire for the primary
    And CNPGReplicaDown may fire for replica 1
    And CNPGReplicaDown may fire for replica 2
    And CNPGReplicaLag resolves for replica 2 < 120 s
    And CNPGReplicaDown resolves for the primary < 120 s
    And CNPGReplicaDown resolves for replica 1 < 120 s
    And CNPGReplicaDown resolves for replica 2 < 120 s
    And writing is healthy < 720 s

  @replica-down
  Scenario: CNPGReplicaDown: a replica's node is lost for over 5 minutes
    When replica 1's node is killed
    Then CNPGReplicaDown critical fires for replica 1 < 420 s after the kill
    And Alertmanager sends CNPGReplicaDown critical for replica 1 < 60 s
    And the primary is still primary
    When the node starts
    Then the cluster is healthy < 600 s
    And CNPGReplicaDown resolves for replica 1 < 120 s
    And Alertmanager sends the resolved CNPGReplicaDown critical for replica 1 < 360 s

  @replica-lag
  Scenario: CNPGReplicaLag: replay pauses on a replica while the client writes
    Replica 2 confirms the commits, so writes go on.

    When replay on replica 1 is paused
    Then CNPGReplicaLag critical fires for replica 1 < 300 s
    And Alertmanager sends CNPGReplicaLag critical for replica 1 < 60 s
    When replay on replica 1 is resumed
    Then CNPGReplicaLag resolves for replica 1 < 120 s
    And Alertmanager sends the resolved CNPGReplicaLag critical for replica 1 < 360 s

  @writes-blocked
  Scenario: CNPGWritesBlocked: no replica applies the commits
    Replay pauses on both replicas, so every commit waits for a standby to
    apply it, as when no synchronous standby confirms. Reads go on. A row is
    written first, so the table the commit inserts into exists before the
    pause.

    When a row is written
    And replay on replica 1 and replica 2 is paused
    And a commit is started on the primary
    Then CNPGWritesBlocked critical fires for the primary < 120 s
    And Alertmanager sends CNPGWritesBlocked critical for the primary < 60 s
    When replay on replica 1 and replica 2 is resumed
    Then the commit is done < 60 s
    And CNPGWritesBlocked resolves for the primary < 120 s
    And Alertmanager sends the resolved CNPGWritesBlocked critical for the primary < 360 s

  @backup-failing
  Scenario: CNPGBackupFailing: WAL archiving fails while the store is down
    A stopped store refuses connections, so each archive call fails at once.
    The primary keeps its WAL until the store is back.

    When the store is stopped
    And a row is written
    And the primary's WAL is switched
    Then the primary's WAL is waiting for the store < 60 s
    And CNPGBackupFailing critical fires for the cluster < 780 s
    And Alertmanager sends CNPGBackupFailing critical for the cluster < 60 s
    When the store starts
    Then the primary's WAL is archived < 180 s
    And CNPGBackupFailing resolves for the cluster < 120 s
    And Alertmanager sends the resolved CNPGBackupFailing critical for the cluster < 360 s

  @data-disk-full
  Scenario: CNPGDataDiskFull: a ballast file fills a node's data disk
    Each node keeps its data on a filesystem of its own, which the kubelet
    reports about once a minute. While the critical alert fires,
    Alertmanager mutes the warning, so the disk is filled to 75 % first,
    then to 82 %. A variant's DataVolumeFull fires for the same disk.

    When replica 1's data disk is filled to 75 %
    Then CNPGDataDiskFull warning fires for replica 1 < 480 s
    And Alertmanager sends CNPGDataDiskFull warning for replica 1 < 60 s
    When replica 1's data disk is filled to 82 %
    Then CNPGDataDiskFull critical fires for replica 1 < 480 s
    And Alertmanager sends CNPGDataDiskFull critical for replica 1 < 360 s
    When the ballast is removed
    Then CNPGDataDiskFull resolves for replica 1 < 240 s
    And Alertmanager sends the resolved CNPGDataDiskFull critical for replica 1 < 360 s
    And Alertmanager sends the resolved CNPGDataDiskFull warning for replica 1 < 60 s
    And DataVolumeFull may fire for the cluster

  @certificate-expiring
  Scenario: CNPGCertificateExpiring: the chart's certificates are reissued for 7 and 2 days
    The company CA's ACME role sets the lifetime of the certificates it
    issues. For each reissue it is shortened, then set back. The server
    certificate gets 7 days, under the warning's 14; the replication
    certificate 2 days, under the critical's 3, which mutes its own warning
    in Alertmanager. Then both get the role's 90 days again. A variant's
    CertManagerCertificateExpiring fires for the same certificates.

    When the server certificate is reissued for 7 days
    And the replication certificate is reissued for 2 days
    Then CNPGCertificateExpiring warning fires for the server certificate < 1200 s
    And CNPGCertificateExpiring critical fires for the replication certificate < 300 s
    And Alertmanager sends CNPGCertificateExpiring warning for the server certificate < 360 s
    And Alertmanager sends CNPGCertificateExpiring critical for the replication certificate < 360 s
    When the server certificate is reissued
    And the replication certificate is reissued
    Then CNPGCertificateExpiring resolves for the server certificate < 180 s
    And CNPGCertificateExpiring resolves for the replication certificate < 180 s
    And Alertmanager sends the resolved CNPGCertificateExpiring warning for the server certificate < 360 s
    And Alertmanager sends the resolved CNPGCertificateExpiring critical for the replication certificate < 360 s
    And CertManagerCertificateExpiring may fire for the cluster

  @connections-high
  Scenario: CNPGConnectionsHigh: held sessions on a replica near max_connections
    psql sessions as postgres, each in pg_sleep, bring the sessions CNPG
    counts on the instance to 93 % of max_connections. That leaves the
    connections reserved for superusers free, and a few more for the others.
    The ended sessions' series can count for the rule evaluator's 5 minute
    lookback when no stale marker reaches it, so the alert may take that long
    to resolve.

    When sessions are held on replica 1 up to 93 % of max_connections
    Then CNPGConnectionsHigh critical fires for replica 1 < 480 s
    And Alertmanager sends CNPGConnectionsHigh critical for replica 1 < 60 s
    When the held sessions are ended
    Then CNPGConnectionsHigh resolves for replica 1 < 420 s
    And Alertmanager sends the resolved CNPGConnectionsHigh critical for replica 1 < 360 s

  @compliance-violation
  Scenario: CNPGComplianceViolation: a role the compliance check does not expect
    When an unapproved role is created on the primary
    Then CNPGComplianceViolation critical fires for the cluster < 180 s
    And Alertmanager sends CNPGComplianceViolation critical for the cluster < 60 s
    When the unapproved role is dropped
    Then compliance is healthy < 120 s
    And CNPGComplianceViolation resolves for the cluster < 120 s
    And Alertmanager sends the resolved CNPGComplianceViolation critical for the cluster < 360 s

  @metrics-missing
  Scenario: CNPGMetricsMissing: the exporter loses the grants of the compliance query
    The revoke replicates, so the compliance query fails on every instance,
    while each exporter answers with its other metrics.

    When the exporter's grants are revoked on the primary
    Then CNPGMetricsMissing critical fires for the primary < 900 s
    And CNPGMetricsMissing critical fires for replica 1 < 60 s
    And CNPGMetricsMissing critical fires for replica 2 < 60 s
    And Alertmanager sends CNPGMetricsMissing critical for the primary < 60 s
    And Alertmanager sends CNPGMetricsMissing critical for replica 1 < 60 s
    And Alertmanager sends CNPGMetricsMissing critical for replica 2 < 60 s
    When the exporter's grants are given back on the primary
    Then compliance is healthy < 120 s
    And CNPGMetricsMissing resolves for the primary < 120 s
    And CNPGMetricsMissing resolves for replica 1 < 120 s
    And CNPGMetricsMissing resolves for replica 2 < 120 s
    And Alertmanager sends the resolved CNPGMetricsMissing critical for the primary < 360 s
    And Alertmanager sends the resolved CNPGMetricsMissing critical for replica 1 < 360 s
    And Alertmanager sends the resolved CNPGMetricsMissing critical for replica 2 < 360 s
