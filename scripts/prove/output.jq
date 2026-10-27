# Groups the probe records by probe name into one row each, in the order the
# names first appear. A row's value lists the values of its attempts, each
# once, and the row is ok when every attempt is. The attempts, with their
# targets and output, go under raw.
# Usage: jq -s --arg collected_at TIME --arg node NAME --arg namespace NS
#   --arg cluster NAME -f output.jq
# Exit: 0 with one JSON document, nonzero for invalid input.
def distinct: reduce .[] as $item ([]; if any(.[]; . == $item) then . else . + [$item] end);

. as $records
| {
  kind: "actual",
  source: "prove",
  collected_at: $collected_at,
  node: $node,
  namespace: $namespace,
  cluster: $cluster,
  probes: (
    [$records[].probe] | distinct | map(. as $probe | [$records[] | select(.probe == $probe)])
    | map({
        probe: .[0].probe,
        expected: .[0].expected,
        value: ([.[].value] | distinct | join(", ")),
        ok: all(.[]; .ok),
        raw: map({target, value, actual})
      })
  )
}
