# Rule 5 for the network_policy section: on every instance pod, each named
# source reaches it on exactly the expected ports, and every source can be named.
#
# Input: {facts, values}. Output: a list of sentences.

include "common";
include "expected";

def ports: if includes("all") then "all ports" else map(tostring) | join(", ") end;

(.values | network_sources) as $expected
| [
    .facts.network_policy | to_entries[]
    | .key as $pod | .value as $actual
    | ($expected + $actual | keys_unsorted[]) as $source
    | ($expected[$source] // []) as $want
    | ($actual[$source] // []) as $got
    | if $source | startswith("{") then "rule 5: pod \($pod): a NetworkPolicy source cannot be named: \($source) on \($got | ports)"
      else
        ([$got | extra($want)] | select(. != []) | "rule 5: pod \($pod): source \($source) can connect on \(ports)"),
        ([$want | missing($got)] | select(. != []) | "rule 5: pod \($pod): source \($source) cannot connect on \(ports)")
      end
  ]
