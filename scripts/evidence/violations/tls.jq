# Rule 1 for the tls section: on every instance pod, PostgreSQL
# accepts only the TLS minimum from expected.jq, and the metrics port 9187
# speaks TLS.
#
# Input: {facts}. Output: a list of violations, see at in common.jq.

include "common";
include "expected";

[
  .facts.tls | to_entries[]
  | .key as $pod
  | (if .value.postgresql == "off" then "rule 1: pod \($pod): PostgreSQL runs without TLS"
     elif .value.postgresql != tls_minimum then "rule 1: pod \($pod): PostgreSQL accepts TLS from \(.value.postgresql), not only \(tls_minimum)"
     else empty end | at(["tls", $pod, "postgresql"])),
    (if .value.metrics == "none" then "rule 1: pod \($pod): metrics on 9187 do not use TLS" else empty end | at(["tls", $pod, "metrics"]))
]
