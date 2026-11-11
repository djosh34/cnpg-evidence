Feature: The evidence scripts
  desired.sh, evidence.sh and prove.sh against the cluster, as
  docs/evidence.md and docs/prove.md run them: evidence.sh from the e2e test,
  prove.sh as root on every node, which the e2e test sees through the node
  container's /proc/<pid>/root.

  Background:
    Given the cluster is healthy

  @evidence
  Scenario: The evidence scripts find the cluster as desired
    When desired.sh runs
    And evidence.sh runs
    Then evidence.sh passes
    When prove.sh runs
    Then prove.sh passes
    And compliance is healthy
