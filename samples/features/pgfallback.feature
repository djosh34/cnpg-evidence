Feature: pgfallback from outside the cluster
  The client reads and writes through pgfallback for the whole scenario. It
  also connects to the rw port of each node alone every 0.25 s, which shows
  when rw takes connections, and logs each attempt of pgfallback at rw.
  "pgfallback has been healthy since the <event>" is the report of
  docs/bench.md: rw back, no read or write on a read address that rw should
  have taken, and the last read and write on rw.

  Background:
    Given the cluster is healthy

  @pgfallback-drain
  Scenario: The primary's node is drained
    When the primary's node is drained
    Then the drain is done < 600 s
    And another instance is primary < 60 s
    When the node is uncordoned
    Then the cluster is healthy < 600 s
    When 30 s pass
    Then pgfallback has been healthy since the drain

  @pgfallback-primary-node-loss
  Scenario: The primary's node is lost for 2 minutes
    When the primary's node is killed
    Then another instance is primary < 600 s
    When 120 s pass after the kill
    And the node starts
    Then the cluster is healthy < 600 s
    When 30 s pass
    Then pgfallback has been healthy since the kill

  @pgfallback-replica-node-loss
  Scenario: A replica's node is lost for 2 minutes
    When replica 1's node is killed
    And 120 s pass after the kill
    Then the primary is still primary
    When the node starts
    Then the cluster is healthy < 600 s
    And the primary is still primary
    When 30 s pass
    Then pgfallback has been healthy since the kill
