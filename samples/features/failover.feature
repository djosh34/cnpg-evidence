Feature: Failover
  A killed node is a node container stopped with docker stop -t 0, as a
  lost VM.

  Background:
    Given the cluster is healthy

  @primary-node-loss
  Scenario: The primary's node is lost for 2 minutes
    When the primary's node is killed
    Then another instance is primary < 600 s
    When 120 s pass after the kill
    And the node starts

  @replica-node-loss
  Scenario: A replica's node is lost for 6 minutes
    When replica 1's node is killed
    And 360 s pass
    Then the primary is still primary
    When the node starts
    Then the cluster is healthy < 600 s
    And the primary is still primary
    And CNPGReplicaDown fired for replica 1
    And CNPGReplicaDown resolves for replica 1 < 120 s
