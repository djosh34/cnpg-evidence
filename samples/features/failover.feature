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

  @one-node-left
  Scenario: Two of three nodes are lost for 2 minutes
    One etcd member of three leaves no Kubernetes API, so nothing is
    promoted. Writes stop, as every commit needs a second instance. The
    client reads on through replica 2.

    When the primary's node and replica 1's node are killed
    And 120 s pass after the kill
    Then writing has been down since the kill
    When the nodes start
    Then writing is healthy < 300 s

  @replica-restart-during-primary-loss
  Scenario: A replica's PostgreSQL restarts while the primary's node is lost
    The kubelet starts the killed postgres container again, as after a crash
    or an OOM kill of PostgreSQL.

    When the primary's node is killed
    And 10 s pass
    Then no instance is promoted
    When replica 1's postgres container is killed
    Then replica 1's postgres container is running < 300 s
    And another instance is primary < 600 s
    When 120 s pass after the kill
    And the node starts

  @quiet-failover
  Scenario: A failover with no writes, the old primary back once the new one is idle
    A former primary that rewinds onto an idle primary just after a WAL
    switch waits for that primary's next WAL record (docs/samples.md). The
    catalog read writes the new primary's hint bits now, so the rejoin writes
    no WAL. The old primary's node is down for over 5 minutes, so
    CNPGReplicaDown fires for it. One write ends the wait.

    Given no writes
    When the primary's node is killed
    Then another instance is primary < 600 s
    When the catalog is read on the new primary
    Then CNPGReplicaDown fires for the primary < 420 s after the kill
    And the new primary is idle after a WAL switch < 900 s
    When the node starts
    And 600 s pass
    And a row is written
    Then the cluster is healthy < 10 s
    And CNPGReplicaDown resolves for the primary < 120 s
