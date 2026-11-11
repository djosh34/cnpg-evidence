@always
Feature: What always holds
  The e2e test runs this scenario after every scenario, passed or failed, with
  the same steps. Reading and writing are what the client, the application
  outside the cluster, gets through pgfallback over the whole scenario. A
  scenario's own "writing is healthy < N s" sets N for that scenario; every
  other limit here holds for every scenario. The alerts are healthy when
  none fires, every alert the scenario says fired or fires did, and no other
  fired but those it says may fire.

  Scenario: After every scenario
    Then the cluster is healthy < 600 s
    And reading is healthy < 5 s
    And writing is healthy < 180 s
    And no acknowledged write is lost
    And the alerts are healthy < 180 s
    And the dashboard is healthy < 180 s
