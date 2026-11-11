Feature: Switchover
  A promotion is kubectl cnpg promote.

  Background:
    Given the cluster is healthy

  @switchover
  Scenario: A switchover to a replica
    When replica 1 is promoted
    Then replica 1 is primary < 300 s

  @rollout
  Scenario: A rollout of a new instance image, then a switchover
    A new image of the same major version, as in a minor upgrade: CNPG
    restarts the replicas, then the primary in place. PostgreSQL starts with
    CNPG's own pg_ident lines only; the chart's lines come back at the
    instance's next reconcile.

    Given the chart's pg_ident lines are on every instance
    When the instance image is changed
    Then every instance is on the new image < 600 s
    And the chart's pg_ident lines are on every instance < 600 s after the change
    And the cluster is healthy < 600 s after the change
    And the primary is still primary
    When replica 1 is promoted
    Then replica 1 is primary < 300 s
    And writing is healthy < 30 s

  @quiet-rewind
  Scenario: A switchover with no writes
    A former primary that rewinds onto an idle primary can wait for that
    primary's next WAL record (docs/samples.md). One write ends the wait.

    Given no writes
    When replica 1 is promoted
    Then replica 1 is primary < 300 s
    When 600 s pass
    And a row is written
    Then the cluster is healthy < 10 s
