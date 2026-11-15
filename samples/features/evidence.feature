Feature: The evidence scripts
  evidence.sh, prove.sh and the compliance metrics against the cluster, one
  part per scenario, so that a gap in one part never hides another.
  evidence.sh runs from the e2e test, as docs/evidence.md says, one part at
  a time. prove.sh runs as root on every node, as docs/prove.md says, which
  the e2e test sees through the node container's /proc/<pid>/root.

  Background:
    Given the cluster is healthy

  @evidence-client-ca
  Scenario: The client CA is the one desired
    When the client-ca part of evidence.sh runs
    Then the client-ca part of evidence.sh passes

  @evidence-logins
  Scenario: The pg_hba and pg_ident lines are the ones desired
    When the logins part of evidence.sh runs
    Then the logins part of evidence.sh passes

  @evidence-postgres
  Scenario: PostgreSQL's roles, rights and databases are the ones desired
    When the postgres part of evidence.sh runs
    Then the postgres part of evidence.sh passes

  @evidence-pods
  Scenario: Every instance pod exists, in its own user namespace
    When the pods part of evidence.sh runs
    Then the pods part of evidence.sh passes

  @evidence-tls
  Scenario: PostgreSQL and the metrics port use TLS as desired
    When the tls part of evidence.sh runs
    Then the tls part of evidence.sh passes

  @evidence-kubernetes
  Scenario: Only the allowed subjects hold the rights of the rules
    When the kubernetes part of evidence.sh runs
    Then the kubernetes part of evidence.sh passes

  @prove
  Scenario: prove.sh finds every node as desired
    When desired.sh runs
    And prove.sh runs
    Then prove.sh passes

  @compliance
  Scenario: Every instance reports the compliance checks as passing
    It also checks the metric CNPGTransactionIDWraparound reads, which no
    scenario causes (docs/monitoring.md).

    When 30 s pass
    Then compliance is healthy
    And cnpg_pg_database_xid_age is exported for every database
