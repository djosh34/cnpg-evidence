# The expected values of evidence.sh, from the desired values and fixed CNPG
# facts. The violation sections and scripts/desired both read them here, so
# the checks and the desired document cannot disagree. Include it with
# `include "expected";`, run as jq -L scripts/evidence/violations.
#
# Unless a def takes arguments only, its input is the desired values: desired.yaml as JSON.

# The release names in samples/values-*.yaml fix these ServiceAccount names;
# cert-manager runs in its own namespace.
def operator_account: "cnpg-cloudnative-pg";
def plugin_account: "barman-cloud-plugin-barman-cloud";
def cert_manager_namespace: "cert-manager";

# The lowest TLS version PostgreSQL may accept: TLSv1.3, CNPG's default.
def tls_minimum: "TLSv1.3";

# True when the values have every key evidence.sh and desired.sh read, with
# the right types; false for any other input.
def valid_values:
  try (
    all(.cluster.name, .cluster.namespace, .caSecret, .rwLoadBalancer.name,
        .network.operatorNamespace, .network.otelNamespace, .replication.commonName;
        type == "string" and . != "")
    and (.cluster.instances | type == "number")
    and (.databases | type == "array")
    and all(.databases[]; (.name, .role | type == "string") and (.clientCNs | type == "array"))
  ) catch false;

def values_needed:
  "the desired state needs cluster.name, cluster.namespace, cluster.instances, caSecret, rwLoadBalancer.name, network.operatorNamespace, network.otelNamespace, replication.commonName and databases with name, role and clientCNs";

# The roles that hold each special right. CNPG's own roles: postgres is the
# superuser, streaming_replica replicates and reads files for pg_rewind.
def role_rights:
  {
    superusers: ["postgres"],
    can_create_roles: ["postgres"],
    can_create_databases: ["postgres"],
    can_replicate: ["postgres", "streaming_replica"],
    can_bypass_row_security: ["postgres"],
    can_run_server_programs: ["postgres"],
    can_read_server_files: ["postgres", "streaming_replica"],
    can_write_server_files: ["postgres"],
    can_read_all_data: ["postgres"],
    can_write_all_data: ["postgres"]
  };

# CNPG's roles, cnpg_metrics_exporter logs in for metrics, and one role per database.
def expected_roles: ["postgres", "streaming_replica", "cnpg_metrics_exporter"] + [.databases[].role];

# Per database, and replication for physical replication: the owner, who
# holds CONNECT (PostgreSQL's default: PUBLIC and the owner) and who logs in how.
def expected_databases:
  . as $values
  | {os_users: ["postgres"]} as $over_socket
  | {postgres: $over_socket, cnpg_metrics_exporter: $over_socket} as $cnpg_local
  | {common_names: ([$values.replication.commonName, "streaming_replica"] | sort)} as $replica
  | def database($owner; $logins): {owner: $owner, connect: (["PUBLIC", $owner] | sort), logins: $logins};
    {
      postgres: database("postgres"; $cnpg_local + {streaming_replica: $replica}),
      template0: {owner: "postgres", allows_connections: false},
      template1: database("postgres"; $cnpg_local),
      replication: {logins: {streaming_replica: $replica}}
    }
    + ([$values.databases[]
        | {key: .name, value: database(.role; $cnpg_local + {(.role): {common_names: (.clientCNs | sort)}})}]
       | from_entries);

# pg_hba and pg_ident as the pg_hba_file_rules and pg_ident_file_mappings
# views show them, in matching order: CNPG 1.30's fixed lines around the
# lines of samples/chart.
def expected_pg_hba:
  [
    "local all cnpg_metrics_exporter peer map=cnpg_metrics_exporter",
    "local all all peer map=local",
    "hostssl postgres streaming_replica all cert map=cnpg_streaming_replica clientcert=verify-full",
    "hostssl replication streaming_replica all cert map=cnpg_streaming_replica clientcert=verify-full",
    "hostssl all cnpg_pooler_pgbouncer all cert map=cnpg_pooler_pgbouncer clientcert=verify-full",
    (.databases[] | "hostssl \(.name) \(.role) all cert map=clients clientcert=verify-full"),
    "host all all all reject",
    "host all all all scram-sha-256"
  ];

def expected_pg_ident:
  [
    "local postgres postgres",
    "cnpg_streaming_replica streaming_replica streaming_replica",
    "cnpg_pooler_pgbouncer cnpg_pooler_pgbouncer cnpg_pooler_pgbouncer",
    "cnpg_metrics_exporter postgres cnpg_metrics_exporter",
    "cnpg_streaming_replica \(.replication.commonName) streaming_replica",
    (.databases[] | .role as $role | .clientCNs[] | "clients \(.) \($role)")
  ];

# Per source, the ports it may connect to on every instance pod.
def network_sources:
  {
    outside: [5432],
    "other nodes": [5432],
    "own node": ["all"],
    loadbalancer: [5432],
    "pg pods": [5432, 8000],
    "\(.network.operatorNamespace) operator": [8000],
    (.network.otelNamespace): [9187],
    "other namespaces": []
  };

# The Kubernetes and k3s controllers, which create pods and other objects
# from objects that other subjects write.
def controllers:
  ["system:kube-controller-manager", "k3s-cloud-controller-manager"]
  + (["clusterrole-aggregation-controller", "cronjob-controller", "daemon-set-controller", "deployment-controller",
      "endpoint-controller", "endpointslice-controller", "endpointslicemirroring-controller",
      "generic-garbage-collector", "job-controller", "legacy-service-account-token-cleaner",
      "local-path-provisioner-service-account", "namespace-controller", "persistent-volume-binder",
      "replicaset-controller", "replication-controller", "resourcequota-controller", "statefulset-controller"]
     | map("system:serviceaccount:kube-system:\(.)"));

# The subjects that may hold a right that equals PostgreSQL superuser:
# system:masters, the operator, the plugin, the instances, the API server,
# cert-manager and its cainjector, and the controllers.
def allowed_subjects($operator_account; $plugin_account):
  ["group:system:masters",
   "system:serviceaccount:\(.network.operatorNamespace):\($operator_account)",
   "system:serviceaccount:\(.network.operatorNamespace):\($plugin_account)",
   "system:serviceaccount:\(.cluster.namespace):\(.cluster.name)",
   "kube-apiserver",
   "system:serviceaccount:\(cert_manager_namespace):cert-manager",
   "system:serviceaccount:\(cert_manager_namespace):cert-manager-cainjector"] + controllers;

# The subjects that may request certificates.
def certificate_subjects: ["group:system:masters", "system:serviceaccount:\(cert_manager_namespace):cert-manager"] + controllers;

# Subjects allowed in one namespace only: in cert-manager's, its webhook may
# also read and write Secrets, since it keeps its serving CA there.
def allowed_in($namespace):
  if $namespace == cert_manager_namespace then ["system:serviceaccount:\(cert_manager_namespace):cert-manager-webhook"]
  else [] end;

# The namespaces the evidence reads rights in: the cluster's, the operator's and cert-manager's.
def component_namespaces: [.cluster.namespace, .network.operatorNamespace, cert_manager_namespace] | unique;

# The namespaces where the operator and the plugin may read Secrets.
def secret_namespaces: [.network.operatorNamespace, .cluster.namespace];
