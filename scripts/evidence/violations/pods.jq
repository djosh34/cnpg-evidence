# Rule 5 for the pods: every instance pod exists and runs in its own user
# namespace.
#
# Input: {facts, values}. Output: a list of violations, see at in common.jq.

include "common";

.facts as $facts
| .values.cluster.instances as $instances
| ($facts.details.instances | length) as $running
| [
    ($facts.pods_sharing_host_uids[] | "rule 5: pod \(.) shares host uids" | at(["pods_sharing_host_uids"])),
    (if $running < $instances then "rule 5: only \($running) of \($instances) instance pods exist" | at(["details", "instances"])
     else empty end)
  ]
