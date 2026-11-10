Feature: Recovery
  Backups, the WAL the primary keeps, the WAL in the store, and a fence.

  Background:
    Given the cluster is healthy

  @backup-restore
  Scenario: A backup, then a new cluster restored from it
    Writing stops before the last WAL switch, so the store holds every
    acknowledged write; the reads go on.

    When a backup is taken
    Then the backup is done < 600 s
    When 30 s pass
    And writing stops
    And the primary's WAL is switched
    Then the primary's WAL is archived < 120 s
    When pg-restore is restored from the store
    Then pg-restore is healthy < 900 s
    And no acknowledged write is lost in pg-restore
    And compliance on pg-restore is healthy < 120 s

  @replica-down-long
  Scenario: A replica catches up from the WAL the primary keeps, without the store
    1229 MB of WAL is more than CNPG's default wal_keep_size of 512 MB. The
    timing table gives how far behind replica 1 was when its pod turned
    ready.

    When replica 1's node is killed
    And 1229 MB of WAL is written on the primary
    And 360 s pass after the kill
    And the store is stopped
    And the node starts
    Then replica 1 is caught up < 600 s
    When the store starts
    Then CNPGReplicaDown fired for replica 1

  @rejoin-from-archive
  Scenario: A replica, then the old primary, rejoin with WAL from the store
    With wal_keep_size 64MB, an instance that was down while 256 MB were
    written must read WAL from the store. Replica 1 is behind while it does;
    the new primary's commits wait until the other replica streams from it.

    When wal_keep_size is set to 64MB
    Then wal_keep_size is 64MB on every instance < 300 s
    And the cluster is healthy < 600 s
    When replica 1's node is killed
    And 256 MB of WAL is written on the primary
    Then the WAL replica 1 needs is gone from the primary < 120 s
    When the node starts
    Then the cluster is healthy < 600 s
    When the primary's node is killed
    Then another instance is primary < 600 s
    When 256 MB of WAL is written on the new primary
    Then the WAL the primary needs is gone from the new primary < 120 s
    When the node starts
    Then CNPGReplicaLag may fire for replica 1
    And CNPGWritesBlocked may fire for the new primary

  @fence
  Scenario: The primary is fenced for 30 s
    PostgreSQL starts again with CNPG's own pg_ident lines only; until the
    chart's lines are back, certificate logins fail, replication included.

    Given the chart's pg_ident lines are on every instance
    When the primary is fenced
    Then the primary is down < 120 s
    When 30 s pass after the fence
    And the primary is unfenced
    Then the chart's pg_ident lines are on the primary < 600 s
    And the cluster is healthy < 600 s after the unfence
    And the primary is still primary
    And writing is healthy < 630 s
