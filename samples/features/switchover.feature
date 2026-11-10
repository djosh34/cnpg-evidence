Feature: Switchover
  A promotion is kubectl cnpg promote.

  Background:
    Given the cluster is healthy

  @switchover
  Scenario: A switchover to a replica
    When replica 1 is promoted
    Then replica 1 is primary < 300 s
