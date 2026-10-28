# The ports section: every Service in any namespace that sends connections to
# an instance pod, and the host ports of the instance pods. A Service reaches
# a pod by its selector, which matches pods of its own namespace only, or by
# an address in one of its EndpointSlices, which can be written by hand for a
# Service without a selector in any namespace.
#
# Input: {services, endpoint_slices, pods (the instance pods), namespace}

def selects($labels): all(to_entries[]; $labels[.key] == .value);

def selector_text:
  if (.spec.selector // {}) == {} then "none"
  else .spec.selector | to_entries | sort_by(.key) | map("\(.key)=\(.value)") | join(",")
  end;

def with_protocol($text): if (.protocol // "TCP") == "TCP" then $text else "\(.protocol)/\($text)" end;

# A Service with a selector sends each port to its targetPort. One without
# a selector sends it to the port of the same name and protocol in its
# EndpointSlices, where a port without a number means every port. A Service
# without ports, which only a headless one may be, limits no port: its name
# leads to the pods on every port.
def service_ports($slice_ports):
  if (.spec.ports // []) == [] then ["all"]
  elif (.spec.selector // {}) != {} then [.spec.ports[] | with_protocol("\(.port) -> \(.targetPort // .port)")]
  else
    [.spec.ports[] as $port
     | [$slice_ports[] | select([.name // "", .protocol // "TCP"] == [$port.name // "", $port.protocol // "TCP"]) | .port // "all"]
     | (unique[] // "none") as $target
     | $port | with_protocol("\(.port) -> \($target)")]
  end;

def service($slice_ports):
  {
    type: .spec.type,
    selector: selector_text,
    traffic_policy: (.spec.externalTrafficPolicy // "none"),
    ports: service_ports($slice_ports),
    node_ports: [.spec.ports[]?.nodePort | select(. != null)],
    health_check_port: (if .spec.healthCheckNodePort then "present" else "none" end),
    external_ips: (.spec.externalIPs // [])
  };

def host_ports:
  [(.spec.containers[], .spec.initContainers[]?) | .ports[]? | select(.hostPort) | with_protocol("\(.hostPort) -> \(.containerPort)")];

if .pods == [] then error("no instance pods") else . end
| .namespace as $namespace
| [.pods[].metadata.labels] as $labels
| [.pods[].status.podIPs[]?.ip] as $addresses
# Per Service, the ports of its EndpointSlices that hold an instance address.
| (reduce (.endpoint_slices[]
           | select(.metadata.labels["kubernetes.io/service-name"] and any(.endpoints[]?.addresses[]; IN($addresses[]))))
     as $slice ({}; .["\($slice.metadata.namespace)/\($slice.metadata.labels["kubernetes.io/service-name"])"] += ($slice.ports // [])))
  as $by_address
| {
    services: ([.services[]
                | "\(.metadata.namespace)/\(.metadata.name)" as $id
                | select(($by_address | has($id))
                         or (.metadata.namespace == $namespace and (.spec.selector // {}) != {}
                             and (.spec.selector as $selector | any($labels[]; . as $pod | $selector | selects($pod)))))
                | {key: $id, value: service($by_address[$id] // [])}]
               | from_entries),
    host_ports: (.pods | map({key: .metadata.name, value: host_ports}) | from_entries)
  }
