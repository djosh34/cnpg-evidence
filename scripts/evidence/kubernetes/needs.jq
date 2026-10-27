# Every question the kubernetes section needs answered: for each subject and
# right, where it applies (in: a namespace, or "" for cluster-wide) and how
# to ask the API server (ask: verb, resource, subresource, namespace; "-"
# for none or all namespaces).
#
# A Role can grant a verb on named objects only (resourceNames). The API
# server answers a question about a named object yes for such a grant and for
# a grant on every object, so existing objects are asked by name: the
# instance pods, the Cluster, Secrets, NetworkPolicies, nodes, the
# ServiceAccounts of CNPG and cert-manager, system:masters and cluster-admin.
# create cannot be limited to a name, so it is asked without one.
#
# A right in a namespace comes from a ClusterRoleBinding or a RoleBinding in
# that namespace. Where no RoleBinding there names the subject or one of its
# groups, the cluster-wide answer is the same, so that one is asked instead.
#
# Input: {subjects, named_in, namespaces, namespace, cluster, component_namespaces,
#         secrets: {<namespace>: [name]}, instance_pods, network_policies, nodes,
#         accounts: [{namespace, name}], operator_namespace, operator_account,
#         plugin_account, ingress_routes}

def write: "create", "update", "patch";

# Pods and Secrets in each namespace of CNPG and cert-manager.
def rights_in_component_namespace($secrets):
  [
    {right: "exec_into_pods", verb: ("get", "create"), resource: "pods", subresource: ("exec", "attach")},
    {right: "exec_into_pods", verb: "patch", resource: "pods", subresource: "ephemeralcontainers"},
    {right: "change_pods", verb: ("update", "patch"), resource: "pods"},
    ($secrets[] | {right: "read_secret \(.)", verb: "get", resource: "secrets/\(.)"}),
    {right: "read_secret all (list)", verb: "list", resource: "secrets"},
    {right: "read_secret all (watch)", verb: "watch", resource: "secrets"},
    {right: "write_secret all (create)", verb: "create", resource: "secrets"},
    ($secrets[] | {right: "write_secret \(.)", verb: ("update", "patch"), resource: "secrets/\(.)"})
  ];

# The instance pods, their ServiceAccount token, the objects that configure
# the cluster, and the Endpoints and EndpointSlices, which decide where the
# cluster's Services send connections, in the cluster's namespace.
def rights_in_cluster_namespace($cluster; $pods; $policies):
  [
    ($pods[]
     | {right: "exec_into_pods", verb: ("get", "create"), resource: "pods/\(.)", subresource: ("exec", "attach")},
       {right: "exec_into_pods", verb: "patch", resource: "pods/\(.)", subresource: "ephemeralcontainers"},
       {right: "change_pods", verb: ("update", "patch"), resource: "pods/\(.)"}),
    {right: "create_pg_tokens", verb: "create", resource: "serviceaccounts/\($cluster)", subresource: "token"},
    {right: "change clusters", verb: "create", resource: "clusters.postgresql.cnpg.io"},
    {right: "change clusters", verb: ("update", "patch"), resource: "clusters.postgresql.cnpg.io/\($cluster)"},
    ({databases: "postgresql.cnpg.io", databaseroles: "postgresql.cnpg.io", subscriptions: "postgresql.cnpg.io",
      poolers: "postgresql.cnpg.io", objectstores: "barmancloud.cnpg.io"}
     | to_entries[]
     | {right: "change \(.key)", verb: write, resource: "\(.key).\(.value)"}),
    {right: "change endpoints", verb: write, resource: "endpoints"},
    {right: "change endpointslices", verb: write, resource: "endpointslices.discovery.k8s.io"},
    {right: "change networkpolicies", verb: (write, "delete"), resource: "networkpolicies.networking.k8s.io"},
    ($policies[] | {right: "change networkpolicies", verb: ("update", "patch", "delete"),
                    resource: "networkpolicies.networking.k8s.io/\(.)"})
  ];

def rights_cluster_wide($nodes):
  [
    {right: "proxy_to_nodes", verb: "get", resource: ("nodes", "nodes/\($nodes[])"), subresource: "proxy"},
    {right: "impersonate", verb: "impersonate", resource: ("users", "groups", "serviceaccounts", "groups/system:masters")},
    {right: "bind_or_escalate_roles", verb: ("bind", "escalate"),
     resource: ("roles.rbac.authorization.k8s.io", "clusterroles.rbac.authorization.k8s.io",
                "clusterroles.rbac.authorization.k8s.io/cluster-admin")},
    {right: "change_webhooks", verb: write,
     resource: ("mutatingwebhookconfigurations.admissionregistration.k8s.io",
                "validatingwebhookconfigurations.admissionregistration.k8s.io")}
  ];

# Impersonating one of these ServiceAccounts gives its rights.
def impersonate_account: {right: "impersonate", verb: "impersonate", resource: "serviceaccounts/\(.name)"};

# A pod can listen on a node port (hostPort, hostNetwork); a Service of type
# LoadBalancer gets a port on every node from servicelb; an Ingress or a
# Traefik IngressRoute is served on the ingress controller's ports on the
# nodes. A changed workload can do the same as a new one.
def rights_in_every_namespace($ingress_routes):
  [
    {right: "run_pods", verb: write,
     resource: ("pods", "replicationcontrollers", "deployments.apps", "statefulsets.apps", "daemonsets.apps",
                "replicasets.apps", "jobs.batch", "cronjobs.batch")},
    {right: "change_services", verb: write, resource: "services"},
    {right: "change_ingresses", verb: write,
     resource: ("ingresses.networking.k8s.io", if $ingress_routes then "ingressroutes.traefik.io" else empty end)},
    {right: "create_certificates", verb: "create",
     resource: ("certificates.cert-manager.io", "certificaterequests.cert-manager.io")},
    {right: "create_certificates", verb: ("update", "patch"), resource: "certificates.cert-manager.io"}
  ];

# The groups a subject is in when asked as itself.
def groups_of:
  if startswith("system:serviceaccount:") then
    split(":")[2] as $namespace
    | ["group:system:serviceaccounts", "group:system:serviceaccounts:\($namespace)", "group:system:authenticated"]
  else ["group:system:authenticated"]
  end;

def ask_namespace($subject; $namespace; $named_in):
  if $namespace == "" then "-"
  elif any(($named_in[$namespace] // [])[]; IN($subject, ($subject | groups_of)[])) then $namespace
  else "-"
  end;

def need($subject; $in; $named_in):
  {right, in: $in, subject: $subject,
   ask: {verb, resource, subresource: (.subresource // "-"), namespace: ask_namespace($subject; $in; $named_in)}};

. as $input
| .named_in as $named_in
| (
    .subjects[] as $subject
    | ($input.component_namespaces[] as $namespace
       | rights_in_component_namespace($input.secrets[$namespace] // [])[] | need($subject; $namespace; $named_in)),
      (rights_in_cluster_namespace($input.cluster; $input.instance_pods; $input.network_policies)[]
       | need($subject; $input.namespace; $named_in)),
      (rights_cluster_wide($input.nodes)[] | need($subject; ""; $named_in)),
      ($input.accounts[] as $account | $account | impersonate_account | need($subject; $account.namespace; $named_in)),
      ($input.namespaces[] as $namespace
       | rights_in_every_namespace($input.ingress_routes)[] | need($subject; $namespace; $named_in))
  ),
  (
    {operator: $input.operator_account, plugin: $input.plugin_account}
    | to_entries[]
    | .key as $who
    | "system:serviceaccount:\($input.operator_namespace):\(.value)" as $account
    | $input.namespaces[] as $namespace
    | ({verb: ("get", "list", "watch"), resource: "secrets"},
       {verb: "get", resource: "secrets/\(($input.secrets[$namespace] // [])[])"})
    | {right: "\($who)_reads_secrets_in"} + .
    | need($account; $namespace; $named_in)
  )
