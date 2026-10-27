# Assembles the actual document from the collected facts and the check records.
# Usage: jq -s --slurpfile facts FILE --arg collected_at TIME --arg node NAME
#   -f output.jq <checks
#   An empty node name means the collected hostname.
# Exit: 0 with one JSON document, nonzero for invalid input.
{
  kind: "actual",
  source: "host-check",
  collected_at: $collected_at,
  node: (if $node == "" then $facts[0].hostname else $node end),
  collected: $facts[0],
  checks: .
}
