# Rule 5 for the pods: every instance pod exists and runs in its own user
# namespace.
#
# Input: {facts, values}. Output: a list of sentences.

.facts as $facts
| .values.cluster.instances as $instances
| ($facts.details.instances | length) as $running
| [
    ($facts.pods_sharing_host_uids[] | "rule 5: pod \(.) shares host uids"),
    (if $running < $instances then "rule 5: only \($running) of \($instances) instance pods exist" else empty end)
  ]
