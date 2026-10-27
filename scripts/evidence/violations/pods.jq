# Rules 6 and 8 for the pods: every instance pod exists and runs in its own
# user namespace, and no hostNetwork pod can bind a port below 1024 on its node.
#
# Input: {facts, values}. Output: a list of sentences.

.facts as $facts
| .values.cluster.instances as $instances
| ($facts.details.instances | length) as $running
| [
    ($facts.pods_sharing_host_uids[] | "rule 6: pod \(.) shares host uids"),
    (if $running < $instances then "rule 6: only \($running) of \($instances) instance pods exist" else empty end),
    ($facts.host_network_pods_that_can_bind_low_ports[] | "rule 8: pod \(.) runs on the host network and can bind a port below 1024")
  ]
