# The desired host-check document: every check of host-check.sh, in its
# order, with the value it has when it passes (docs/host-check.md, Checks).
# The same on every node, so it has no node and no collected facts.
#
# Usage: jq -n -f host-check.jq

{
  kind: "desired",
  source: "host-check",
  checks: ([
    ["selinux-enforcing", "enforcing"],
    ["postgres-uid-account", "none"],
    ["postgres-gid-group", "none"],
    ["postgres-sudoers", "none"],
    ["postgresql-server-absent", "none"],
    ["storage-dir-mode", "700 or tighter, root:root, no ACL"],
    ["kubelet-pods-mode", "750 or tighter, root:root, no ACL"],
    ["k3s-kubeconfig-mode", "600 or tighter, root:root, no ACL"],
    ["k3s-selinux", "true"],
    ["k3s-network-policy", "none"],
    ["subordinate-ids", "none"],
    ["unprivileged-port-start", "1024 or higher"],
    ["bind-service-capability", "none"]
  ] | map({id: .[0], ok: true, value: .[1]}))
}
