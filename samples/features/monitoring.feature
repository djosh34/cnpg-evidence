Feature: Monitoring
  The alert rules and the dashboard, against the events they are for.

  Background:
    Given the cluster is healthy

  @exporter-node-loss
  Scenario: The exporters keep their query metrics while nodes are lost for over 5 minutes
    Each node is lost for longer than the 5 min after which Kubernetes marks
    its pods for deletion. While CNPGReplicaDown fires for replica 1, the
    sample's Alertmanager configuration mutes its CNPGMetricsMissing, and
    not that of replica 2.

    Given the exporters are healthy < 60 s
    When replica 1's node is killed
    Then CNPGReplicaDown fires for replica 1 < 420 s after the kill
    And Alertmanager sends CNPGReplicaDown for replica 1 < 60 s
    When Alertmanager gets CNPGMetricsMissing for replica 1
    And Alertmanager gets CNPGMetricsMissing for replica 2
    Then Alertmanager mutes CNPGMetricsMissing for replica 1 < 60 s
    And Alertmanager sends CNPGMetricsMissing for replica 2 < 60 s
    When 400 s pass after the kill
    Then the primary is still primary
    And the exporters of the primary and replica 2 have been healthy since the kill
    When the node starts
    Then the cluster is healthy < 600 s
    And the exporters are healthy < 60 s
    When the primary's node is killed
    Then another instance is primary < 600 s
    And CNPGReplicaDown fires for the primary < 420 s after the kill
    When 400 s pass after the kill
    Then the exporters of replica 1 and replica 2 have been healthy since the kill
    When the node starts
    Then the cluster is healthy < 600 s
    And the exporters are healthy < 60 s

  @replica-not-streaming
  Scenario: A replica stops streaming while its exporter keeps answering
    In the replica pod's network namespace a firewall rule rejects its
    connections to port 5432, and the primary ends its WAL sender. Without a
    WAL receiver, the replica reports the age of its last transaction as its
    lag, so CNPGReplicaLag fires too.

    When replica 1 is cut off
    Then replica 1 is not streaming < 60 s
    And CNPGReplicaDown fires for replica 1 < 480 s
    And replica 1's metrics are arriving
    When replica 1 is reconnected
    Then the cluster is healthy < 600 s
    And CNPGReplicaDown resolves for replica 1 < 120 s
    And CNPGReplicaLag fired for replica 1

  @lag-and-stall
  Scenario: A replica falls behind, a long statement, and a commit that waits
    Replay pauses on replica 1 while the client writes. Then a 15 s
    statement, whose commit waits only a moment for its standby. Then replay
    pauses on both replicas, so a commit waits for a standby to apply it, as
    when no synchronous standby confirms.

    When replay on replica 1 is paused
    Then CNPGReplicaLag fires for replica 1 < 300 s
    And Alertmanager sends CNPGReplicaLag for replica 1 < 60 s
    When replay on replica 1 is resumed
    Then CNPGReplicaLag resolves for replica 1 < 120 s
    When a 15 s statement is committed on the primary
    And 15 s pass
    Then CNPGWritesBlocked has not fired for the primary
    When replay on replica 1 and replica 2 is paused
    And a commit is started on the primary
    Then CNPGWritesBlocked fires for the primary < 120 s
    And Alertmanager sends CNPGWritesBlocked for the primary < 60 s
    When replay on replica 1 and replica 2 is resumed
    Then CNPGWritesBlocked resolves for the primary < 120 s
    And the commit is done

  @lag-after-primary-change
  Scenario: No false replica lag after a switchover and after a fence
    CNPG's own cnpg_pg_replication_lag reports minutes on a caught-up replica
    for up to 5 min after its PostgreSQL restarts; the chart's
    cnpg_replica_lag_seconds must not. The timing table gives the most each
    reported.

    When replica 1 is promoted
    Then replica 1 is primary < 300 s
    And the cluster is healthy < 600 s
    And the replica lag is healthy for 330 s
    When replica 1 is fenced
    And 30 s pass after the fence
    And replica 1 is unfenced
    Then the cluster is healthy < 600 s
    And replica 1 is still primary
    And the replica lag is healthy for 330 s
