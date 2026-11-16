Feature: k3s
  The k3s CAs rotate as docs.k3s.io says for the CAs k3s made itself, with
  the tools of the pinned k3s version. Its rotate-default-ca-certs.sh makes a
  new CA for the server, client, request-header, etcd server and etcd peer
  certificates, each cross-signed by the old one, and a new service account
  key that keeps the old one. k3s certificate rotate-ca stores them in etcd.
  k3s then restarts on one node after another, as systemctl restart k3s
  does, and makes that node's certificates from the new CAs. The pods keep
  running while k3s restarts.

  Background:
    Given the cluster is healthy

  @ca-rotation
  Scenario: The k3s and etcd CAs are rotated while the client writes and reads
    When new k3s CAs are stored in etcd
    And k3s is restarted on node 1
    Then node 1 is on the new CAs < 300 s
    And etcd is healthy < 300 s
    When k3s is restarted on node 2
    Then node 2 is on the new CAs < 300 s
    And etcd is healthy < 300 s
    When k3s is restarted on node 3
    Then node 3 is on the new CAs < 300 s
    And etcd is healthy < 300 s
    And every node is Ready < 300 s
    And the cluster is healthy < 600 s
