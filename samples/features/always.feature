@always
Feature: What always holds
  The bench runs this scenario after every scenario, with the same steps.
  Reading and writing are what the client, the application outside the
  cluster, gets through pgfallback over the whole scenario. A scenario's own
  "reading is healthy < N s" or "writing is healthy < N s" sets N for that
  scenario.

  Scenario: After every scenario
    Then the cluster is healthy < 600 s
    And reading is healthy < 5 s
    And writing is healthy < 180 s
    And no acknowledged write is lost
