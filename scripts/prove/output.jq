# Adds target identity to collected probe records without changing their order.
# Usage: jq -s --arg node NAME --arg namespace NS --arg cluster NAME -f output.jq
# Exit: 0 with one JSON document, nonzero for invalid input.
{node: $node, namespace: $namespace, cluster: $cluster, probes: .}
