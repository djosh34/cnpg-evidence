# The desired host-check document: every check of host-check.sh, in its
# order, with the value it has when it passes (docs/host-check.md, Checks).
# The same on every node, so it has no node and no collected facts.
#
# Usage: jq -n -f host-check.jq

{
  kind: "desired",
  source: "host-check",
  checks: ([
    ["selinux", "enforcing, enable_selinux true"],
    ["postgres-account", "none"],
    ["dir-modes", "none"],
    ["k3s-secrets", "none"],
    ["low-ports", "none"],
    ["k3s-network-policy", "none"]
  ] | map({id: .[0], ok: true, value: .[1]}))
}
