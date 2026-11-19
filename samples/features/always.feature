@always
Feature: What always holds
  The e2e test runs this scenario after every scenario, passed or failed, with
  the same steps. Reading and writing are what the client, the application
  outside the cluster, gets through pgfallback over the whole scenario. A
  scenario's own "writing is healthy < N s" sets N for that scenario; every
  other limit here holds for every scenario. In a variant run the client
  reads and writes on rw only, so its reads stop while the primary changes
  or stops: in a scenario that changes or stops the primary, reading takes
  the limit of writing. The alerts are healthy when none
  fires, every alert the scenario says fired or fires did, and no other
  fired but those it says may fire. Every image on the nodes is one the
  manifest names, as it was before the scenario.

  Scenario: After every scenario
    Then the cluster is healthy < 600 s
    And reading is healthy < 5 s
    And writing is healthy < 180 s
    And no acknowledged write is lost
    And the alerts are healthy < 180 s
    And the dashboard is healthy < 180 s
    And every image on the nodes is from the manifest
