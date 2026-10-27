# Parses ss listeners, preserving process identities alongside addresses.
# Usage: ss -Htlnp | jq -Rn -f listening-tcp.jq
# Exit: 0 with a sorted JSON array, nonzero on jq errors.
[inputs
 | capture("^\\S+\\s+\\S+\\s+\\S+\\s+(?<local>\\S+)\\s+\\S+\\s*(?<users>.*)$")
 | (.local | capture("^(?<address>.*):(?<port>[0-9]+)$")) as $address
 | {address: $address.address, port: ($address.port | tonumber),
    processes: [.users | scan("\"([^\"]*)\",pid=([0-9]+)")
                | {name: .[0], pid: (.[1] | tonumber)}]}]
| sort_by(.port, .address)
