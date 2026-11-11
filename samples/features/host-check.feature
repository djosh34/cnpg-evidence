Feature: host-check.sh on the nodes
  host-check.sh runs as root on every node, a k3s server in a container,
  with a static bash and jq, which the k3s image lacks. A node in a
  container fails some checks; on every node exactly these fail, each with
  this value. docs/host-check.md points here for the list.

  Background:
    Given the cluster is healthy

  @host-check
  Scenario: host-check.sh fails only the known checks of a container node
    When host-check.sh runs
    Then host-check.sh fails exactly these checks on every node:
      | check            | value                                                                       | why                                                                                                                                               |
      | selinux          | disabled; enable_selinux false                                              | The runner's kernel has no SELinux, and k3s runs without --selinux                                                                                |
      | postgres-account | getent not found                                                            | The k3s image has no getent                                                                                                                       |
      | k3s-secrets      | /var/lib/rancher/k3s/server: 755, root:root, no ACL; secrets-encryption off | The bench copies k3s/manifests/ into server/manifests before k3s starts, which makes server/ with 755; the node runs without --secrets-encryption |
      | low-ports        | ip_unprivileged_port_start = 0                                              | Docker sets it to 0 in a container's network namespace                                                                                            |
