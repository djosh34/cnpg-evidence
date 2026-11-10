Feature: A broken store
  Before each event the store breaks and the primary has WAL the store never
  got. A former primary with WAL the store never got waits for the store
  before it rejoins. The new primary's commits wait until a standby streams
  from it.

  Background:
    Given the cluster is healthy

  @store-refuse
  Scenario: A primary node loss and a switchover while the store refuses connections
    A stopped store refuses connections, so each call to it fails at once.

    When the store is stopped
    And the primary's WAL is switched
    Then the primary's WAL is waiting for the store < 60 s
    When the primary's node is killed
    Then another instance is primary < 900 s
    And CNPGWritesBlocked may fire for the new primary
    And writing is healthy < 900 s after the kill
    When 120 s pass after the kill
    And the node starts
    And 60 s pass
    And the store starts
    Then the cluster is healthy < 600 s
    When the store is stopped
    And the new primary's WAL is switched
    Then the new primary's WAL is waiting for the store < 60 s
    When a replica is promoted
    Then the new primary is primary < 900 s
    And CNPGWritesBlocked may fire for the new primary
    And writing is healthy < 900 s after the promote
    When 60 s pass
    And the store starts
    Then writing is healthy < 900 s

  @store-hang
  Scenario: A primary node loss and a switchover while the store never answers
    A paused store takes connections and never answers. barman-cloud sets no
    connect timeout, so each call to it waits about 60 s for the TLS
    handshake (docs/samples.md). The cluster then has no primary for
    minutes, and the alerts of a cluster without a primary may fire.

    When the store is paused
    And the primary's WAL is switched
    Then the primary's WAL is waiting for the store < 60 s
    When the primary's node is killed
    Then another instance is primary < 900 s
    And CNPGWritesBlocked may fire for the new primary
    And writing is healthy < 900 s after the kill
    When 120 s pass after the kill
    And the node starts
    And 60 s pass
    And the store starts
    Then the cluster is healthy < 600 s
    When the store is paused
    And the new primary's WAL is switched
    Then the new primary's WAL is waiting for the store < 60 s
    When a replica is promoted
    Then the new primary is primary < 900 s
    And CNPGWritesBlocked may fire for the new primary
    And writing is healthy < 900 s after the promote
    When 60 s pass
    And the store starts
    Then writing is healthy < 900 s
    And CNPGDatabaseDown may fire for the cluster
    And CNPGReplicaDown may fire for the primary
    And CNPGReplicaLag may fire for the primary
    And CNPGReplicaLag may fire for replica 1
    And CNPGReplicaLag may fire for replica 2
