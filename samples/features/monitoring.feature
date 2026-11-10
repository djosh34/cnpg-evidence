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
