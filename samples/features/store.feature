Feature: A broken store
  Before each event the store breaks and the primary has WAL the store never
  got. A stopped store refuses connections; a paused one never answers. A
  former primary with WAL the store never got waits for the store before it
  rejoins.

  Background:
    Given the cluster is healthy

  Scenario Outline: A primary node loss and a switchover while the store is <broken>
    When the store is <broken>
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
    When the store is <broken>
    And the new primary's WAL is switched
    Then the new primary's WAL is waiting for the store < 60 s
    When a replica is promoted
    Then the new primary is primary < 900 s
    And CNPGWritesBlocked may fire for the new primary
    And writing is healthy < 900 s after the promote
    When 60 s pass
    And the store starts
    Then writing is healthy < 900 s

    @store-refuse
    Examples:
      | broken  |
      | stopped |

    @store-hang
    Examples:
      | broken |
      | paused |
