Feature: host-check.sh on the nodes
  host-check.sh runs as root on every node, a k3s server in a container,
  with a static bash and jq, which the k3s image lacks. A node in a
  container can never pass three checks. host-check-docker checks that they
  fail with exactly their known values, so a change to them shows.
  host-check checks that every other check passes. docs/host-check.md
  points here for the list.

  Background:
    Given the cluster is healthy

  @host-check-docker
  Scenario: host-check.sh fails the three checks a container node cannot pass
    When host-check.sh runs
    Then host-check.sh fails these checks on every node:
      | check            | value                          | why                                                                |
      | selinux          | disabled; enable_selinux false | The runner's kernel has no SELinux, and k3s runs without --selinux |
      | postgres-account | getent not found               | The k3s image has no getent                                        |
      | low-ports        | ip_unprivileged_port_start = 0 | Docker sets it to 0 in a container's network namespace             |

  @host-check
  Scenario: host-check.sh passes every other check
    When host-check.sh runs
    Then host-check.sh passes every check on every node but these:
      | check            | why                                                    |
      | selinux          | A container node cannot pass it; see host-check-docker |
      | postgres-account | A container node cannot pass it; see host-check-docker |
      | low-ports        | A container node cannot pass it; see host-check-docker |
