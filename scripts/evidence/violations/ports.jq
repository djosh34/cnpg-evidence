# Rule 9 for the ports section: only the expected Services send connections
# to the instance pods, each with exactly its expected type, selector, traffic
# policy and ports, and no instance pod has a host port.
#
# Input: {facts, values}. Output: a list of sentences.

include "expected";

def text: if type != "array" then tostring elif . == [] then "none" else map(tostring) | join(", ") end;

def field_name:
  {traffic_policy: "traffic policy", node_ports: "node ports", health_check_port: "health check port",
   external_ips: "external IPs"}[.] // .;

(.values | expected_services) as $expected
| .facts.ports as $ports
| [
    ($ports.services | to_entries[]
     | .key as $id | .value as $got
     | if $expected | has($id) then
         $expected[$id] | to_entries[] | select($got[.key] != .value)
         | "rule 9: Service \($id) has \(.key | field_name) \($got[.key] | text), expected \(.value | text)"
       else
         "rule 9: Service \($id) reaches the instance pods: \($got.type), ports \($got.ports | text), node ports \($got.node_ports | text), external IPs \($got.external_ips | text)"
       end),
    ($expected | keys_unsorted[] as $id | select($ports.services | has($id) | not)
     | "rule 9: Service \($id) does not reach the instance pods"),
    ($ports.host_ports | to_entries[] | .key as $pod | .value[] | "rule 9: pod \($pod) has host port \(.)")
  ]
