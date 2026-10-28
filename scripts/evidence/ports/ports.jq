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

# A Service without ports (a headless one) gives clients the pod addresses, on every port.
def service_ports:
  if (.spec.ports // []) == [] then ["all"]
  else [.spec.ports[] | with_protocol("\(.port) -> \(.targetPort // .port)")]
  end;

def service:
  {
    type: .spec.type,
    selector: selector_text,
    traffic_policy: (.spec.externalTrafficPolicy // "none"),
    ports: service_ports,
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
| [.endpoint_slices[]
   | select(.metadata.labels["kubernetes.io/service-name"] and any(.endpoints[]?.addresses[]; IN($addresses[])))
   | "\(.metadata.namespace)/\(.metadata.labels["kubernetes.io/service-name"])"] as $by_address
| {
    services: ([.services[]
                | "\(.metadata.namespace)/\(.metadata.name)" as $id
                | select(IN($id; $by_address[])
                         or (.metadata.namespace == $namespace and (.spec.selector // {}) != {}
                             and (.spec.selector as $selector | any($labels[]; . as $pod | $selector | selects($pod)))))
                | {key: $id, value: service}]
               | from_entries),
    host_ports: (.pods | map({key: .metadata.name, value: host_ports}) | from_entries)
  }
