# Builds the host-facts object, using null for unavailable values.
# Usage: jq -n with --arg/--slurpfile inputs from collected.sh -f collected.jq
# Exit: 0 with one JSON object, nonzero on jq errors.
def nonempty: if . == "" then null else . end;
{hostname: $hostname, os: $os, kernel: $kernel,
 k3s_version: ($k3s | nonempty), containerd_version: ($containerd | nonempty),
 selinux: $selinux, containerd_enable_selinux: ($containerd_selinux | nonempty),
 postgres_uid: ($postgres_uid | tonumber), postgres_gid: ($postgres_gid | tonumber),
 listening_tcp: $listening_tcp[0], missing_tools: $missing_tools[0]}
