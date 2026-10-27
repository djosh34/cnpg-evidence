# Rules 1 and 5 for the tls section: on every instance pod, PostgreSQL
# accepts only TLSv1.3, CNPG's default, and the metrics port 9187 speaks TLS.
#
# Input: {facts}. Output: a list of sentences.

[
  .facts.tls | to_entries[]
  | .key as $pod
  | (if .value.postgresql == "off" then "rule 1: pod \($pod): PostgreSQL runs without TLS"
     elif .value.postgresql != "TLSv1.3" then "rule 1: pod \($pod): PostgreSQL accepts TLS from \(.value.postgresql), not only TLSv1.3"
     else empty end),
    (if .value.metrics == "none" then "rule 5: pod \($pod): metrics on 9187 do not use TLS" else empty end)
]
