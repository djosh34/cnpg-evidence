# Turns one firewalld zone's command output into structured lists.
# Usage: jq -n with zone/target/interfaces/sources/services/ports/rich_rules
#   string arguments -f firewalld.jq
# Exit: 0 with one JSON object, nonzero on jq errors.
def words: [splits("\\s+") | select(. != "")];
{zone: $zone, target: $target, interfaces: ($interfaces | words),
 sources: ($sources | words), services: ($services | words),
 ports: ($ports | words), rich_rules: ($rich_rules | split("\n") | map(select(. != "")))}
