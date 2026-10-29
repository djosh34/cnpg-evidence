# Every question the kubernetes section needs answered: for each subject and
# right, where it applies (in: a namespace, or "" for cluster-wide), whether
# it only reads Secrets (secret_read), and how to ask the API server (ask:
# verb, resource, subresource, namespace; "-" for none or all namespaces).
#
# A Role can grant a verb on named objects only (resourceNames). The API
# server answers a question about a named object yes for such a grant and for
# a grant on every object, so existing objects are asked by name: the
# instance pods, the Cluster, the Secrets and ConfigMaps of the cluster's
# namespace, nodes, the ServiceAccounts of CNPG and cert-manager,
# system:masters and cluster-admin. create cannot be limited to a name, so it
# is asked without one.
#
# A right in a namespace comes from a ClusterRoleBinding or a RoleBinding in
# that namespace. Where no RoleBinding there names the subject or one of its
# groups, the cluster-wide answer is the same, so that one is asked instead.
#
# Input: {subjects, named_in, namespaces, namespace, cluster,
#         secrets: {<namespace>: [name]}, configmaps: [name in namespace],
#         instance_pods, nodes, accounts: [{namespace, name}], operator_namespace,
#         operator_account, plugin_account,
#         ingress_routes: the Traefik route resources the cluster serves}

def write: "create", "update", "patch";

# Rights in the cluster's namespace that equal PostgreSQL superuser: enter
# or change the instance pods, start a pod that mounts their volumes or runs
# as their ServiceAccount, read or write its Secrets, write its ConfigMaps,
# whose custom queries the instances run, or change the CNPG objects that
# configure the cluster, its roles, databases and backups.
def superuser_in_cluster_namespace($cluster; $pods; $secrets; $configmaps):
  [
    ($pods[]
     | {verb: ("get", "create"), resource: "pods/\(.)", subresource: ("exec", "attach")},
       {verb: "patch", resource: "pods/\(.)", subresource: "ephemeralcontainers"},
       {verb: ("update", "patch"), resource: "pods/\(.)"}),
    {verb: write,
     resource: ("pods", "replicationcontrollers", "deployments.apps", "statefulsets.apps", "daemonsets.apps",
                "replicasets.apps", "jobs.batch", "cronjobs.batch")},
    ($secrets[] | {verb: "get", resource: "secrets/\(.)", secret_read: true}, {verb: ("update", "patch"), resource: "secrets/\(.)"}),
    {verb: ("list", "watch"), resource: "secrets", secret_read: true},
    {verb: "create", resource: "secrets"},
    ($configmaps[] | {verb: ("update", "patch"), resource: "configmaps/\(.)"}),
    {verb: "create", resource: "configmaps"},
    {verb: "create", resource: "serviceaccounts/\($cluster)", subresource: "token"},
    {verb: "create", resource: "clusters.postgresql.cnpg.io"},
    {verb: ("update", "patch"), resource: "clusters.postgresql.cnpg.io/\($cluster)"},
    {verb: write, resource: ("databases.postgresql.cnpg.io", "databaseroles.postgresql.cnpg.io",
                             "objectstores.barmancloud.cnpg.io")}
  ]
  | map({right: "superuser_in_cluster_namespace"} + .);

# A pod can run as any ServiceAccount of its namespace, mount its volumes and
# use hostPort or hostNetwork. cert-manager signs what a Certificate or
# CertificateRequest asks for. An Ingress or a Traefik IngressRoute or
# IngressRouteTCP is served on the ingress controller's ports on the nodes.
def rights_in_every_namespace($ingress_routes):
  [
    {right: "run_pods", verb: write,
     resource: ("pods", "replicationcontrollers", "deployments.apps", "statefulsets.apps", "daemonsets.apps",
                "replicasets.apps", "jobs.batch", "cronjobs.batch")},
    {right: "create_certificates", verb: "create",
     resource: ("certificates.cert-manager.io", "certificaterequests.cert-manager.io")},
    {right: "create_certificates", verb: ("update", "patch"), resource: "certificates.cert-manager.io"},
    {right: "write_routes", verb: write, resource: ("ingresses.networking.k8s.io", $ingress_routes[])}
  ];

# Rights that lead to cluster-admin: the kubelet API of every node, acting as
# another subject, granting rights, or changing what admission webhooks see.
def become_cluster_admin($nodes):
  [
    {verb: "get", resource: ("nodes", "nodes/\($nodes[])"), subresource: "proxy"},
    {verb: "impersonate", resource: ("users", "groups", "serviceaccounts", "groups/system:masters")},
    {verb: ("bind", "escalate"),
     resource: ("roles.rbac.authorization.k8s.io", "clusterroles.rbac.authorization.k8s.io",
                "clusterroles.rbac.authorization.k8s.io/cluster-admin")},
    {verb: write,
     resource: ("mutatingwebhookconfigurations.admissionregistration.k8s.io",
                "validatingwebhookconfigurations.admissionregistration.k8s.io")}
  ]
  | map({right: "become_cluster_admin"} + .);

# Impersonating one of these ServiceAccounts gives its rights.
def impersonate_account: {right: "become_cluster_admin", verb: "impersonate", resource: "serviceaccounts/\(.name)"};

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
  {right, in: $in, subject: $subject, secret_read: (.secret_read // false),
   ask: {verb, resource, subresource: (.subresource // "-"), namespace: ask_namespace($subject; $in; $named_in)}};

. as $input
| .named_in as $named_in
| (
    .subjects[] as $subject
    | (superuser_in_cluster_namespace($input.cluster; $input.instance_pods; $input.secrets[$input.namespace] // [];
                                    $input.configmaps)[]
       | need($subject; $input.namespace; $named_in)),
      (become_cluster_admin($input.nodes)[] | need($subject; ""; $named_in)),
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
