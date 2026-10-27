# The network_policy section: per instance pod, who may open a connection to
# it, as source -> ports, over every NetworkPolicy that selects that pod by
# its labels. A source it cannot name is printed as its raw JSON.
#
# Input: {policies, pods: {<pod>: labels}, node_pod_cidrs, namespace, cluster,
#         load_balancer, operator_namespace, otel_namespace}

def includes($item): any(.[]; . == $item);

def selects($labels):
  all((.matchLabels // {}) | to_entries[]; $labels[.key] == .value)
  and all(.matchExpressions[]?;
    .key as $key
    | if .operator == "In" then $labels[$key] != null and (.values | includes($labels[$key]))
      elif .operator == "NotIn" then $labels[$key] == null or (.values | includes($labels[$key]) | not)
      elif .operator == "Exists" then $labels[$key] != null
      else $labels[$key] == null
      end);

def ingress_policy: .spec.policyTypes // ["Ingress"] | includes("Ingress");

def every_pod: . == null or . == {};

def only_label($key; $value): . == {matchLabels: {($key): $value}};

# The flannel.1 address of a node is the network address of its pod range.
def tunnel_address: split("/")[0] + "/32";

def source_name($input):
  if .ipBlock then
    .ipBlock.cidr as $cidr
    | if $cidr == "0.0.0.0/0" and ((.ipBlock.except // []) | sort) == ($input.node_pod_cidrs | sort) then "outside"
      elif [$input.node_pod_cidrs[] | tunnel_address] | includes($cidr) then "other nodes"
      else tojson
      end
  elif .namespaceSelector == null then
    if .podSelector | only_label("cnpg.io/cluster"; $input.cluster) then "pg pods"
    else tojson
    end
  elif .namespaceSelector == {} and (.podSelector | every_pod) then "other namespaces"
  elif (.namespaceSelector.matchLabels // {} | keys) == ["kubernetes.io/metadata.name"] and .namespaceSelector.matchExpressions == null then
    .namespaceSelector.matchLabels["kubernetes.io/metadata.name"] as $namespace
    | if .podSelector | every_pod then $namespace
      elif .podSelector | only_label("app.kubernetes.io/name"; "cloudnative-pg") then "\($namespace) operator"
      elif $namespace == "kube-system" and .podSelector == {matchLabels: {
          "svccontroller.k3s.cattle.io/svcname": $input.load_balancer,
          "svccontroller.k3s.cattle.io/svcnamespace": $input.namespace}} then "loadbalancer"
      else tojson
      end
  else tojson
  end;

def port_name:
  (if .port == null then "all" else .port end) as $port
  | (if .endPort then "\($port)-\(.endPort)" else $port end) as $range
  | if (.protocol // "TCP") == "TCP" then $range else "\(.protocol)/\($range)" end;

def ports: if (.ports // []) == [] then ["all"] else [.ports[] | port_name] end;

# Numbers first, and "all" stands alone.
def port_list: unique | if includes("all") then ["all"] else . end;

# Who may connect to one pod with these labels.
def sources($input; $labels):
  [$input.policies[] | select(ingress_policy and (.spec.podSelector | selects($labels)))] as $policies
  | [
      if $policies == [] then {source: "everyone", ports: ["all"]} else empty end,
      ($policies[].spec.ingress[]?
       | ports as $ports
       | if (.from // []) == [] then {source: "everyone", ports: $ports}
         else .from[] | {source: source_name($input), ports: $ports}
         end)
    ] as $allowed
  | {
      outside: [],
      "other nodes": [],
      "own node": ["all"],
      loadbalancer: [],
      "pg pods": [],
      "\($input.operator_namespace) operator": [],
      ($input.otel_namespace): [],
      "other namespaces": []
    }
  | reduce $allowed[] as $entry (.; .[$entry.source] += $entry.ports)
  | map_values(port_list);

. as $input
| .pods | map_values(sources($input; .))
