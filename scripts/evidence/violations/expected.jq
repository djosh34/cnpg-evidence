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
        .network.operatorNamespace, .replication.commonName;
        type == "string" and . != "")
    and (.cluster.instances | type == "number")
    and (.databases | type == "array")
    and all(.databases[]; (.name, .role | type == "string") and (.clientCNs | type == "array"))
  ) catch false;

def values_needed:
  "the desired state needs cluster.name, cluster.namespace, cluster.instances, caSecret, rwLoadBalancer.name, network.operatorNamespace, replication.commonName and databases with name, role and clientCNs";

# The roles that hold each special right. CNPG's own roles: postgres is the
# superuser, streaming_replica replicates and reads files for pg_rewind,
# cnpg_metrics_exporter reads pg_ident for the compliance query of samples/chart.
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
    can_write_all_data: ["postgres"],
    can_read_ident_mappings: ["cnpg_metrics_exporter", "postgres"]
  };

# CNPG's roles, cnpg_metrics_exporter logs in for metrics, and one role per database.
def expected_roles: ["postgres", "streaming_replica", "cnpg_metrics_exporter"] + [.databases[].role];

# CNPG's databases and one per database of the values.
def expected_databases: ["postgres", "template0", "template1"] + [.databases[].name];

# The pg_hba lines that log in with a certificate, in matching order: CNPG
# 1.30's fixed lines, then one line per database of the values. Each opens
# one database to one role, whose certificate common names come from the
# pg_ident lines of its map.
def certificate_lines:
  [
    {database: "postgres", role: "streaming_replica", map: "cnpg_streaming_replica"},
    {database: "replication", role: "streaming_replica", map: "cnpg_streaming_replica"},
    {database: "all", role: "cnpg_pooler_pgbouncer", map: "cnpg_pooler_pgbouncer"},
    (.databases[] | {database: .name, role, map: "clients"})
  ];

# pg_hba and pg_ident as the pg_hba_file_rules and pg_ident_file_mappings
# views show them, in matching order: CNPG 1.30's fixed lines around the
# lines of samples/chart.
def expected_pg_hba:
  [
    "local all cnpg_metrics_exporter peer map=cnpg_metrics_exporter",
    "local all all peer map=local",
    (certificate_lines[] | "hostssl \(.database) \(.role) all cert map=\(.map) clientcert=verify-full"),
    "host all all all reject",
    "host all all all scram-sha-256"
  ];

def expected_ident:
  [
    {map: "local", system_user: "postgres", role: "postgres"},
    {map: "cnpg_streaming_replica", system_user: "streaming_replica", role: "streaming_replica"},
    {map: "cnpg_pooler_pgbouncer", system_user: "cnpg_pooler_pgbouncer", role: "cnpg_pooler_pgbouncer"},
    {map: "cnpg_metrics_exporter", system_user: "postgres", role: "cnpg_metrics_exporter"},
    {map: "cnpg_streaming_replica", system_user: .replication.commonName, role: "streaming_replica"},
    (.databases[] | .role as $role | .clientCNs[] | {map: "clients", system_user: ., role: $role})
  ];

def expected_pg_ident: expected_ident | map("\(.map) \(.system_user) \(.role)");

# Who logs in with a certificate, from pg_ident mappings and the certificate
# lines: per mapping of a certificate line's map, its common name, its role,
# and each database a certificate line opens to that role with that map, or
# none.
def certificate_logins($ident):
  certificate_lines as $lines
  | [$ident[] | . as $mapping
     | select(any($lines[]; .map == $mapping.map))
     | ([$lines[] | select(.map == $mapping.map and .role == $mapping.role) | .database]
        | if . == [] then ["none"] else . end)[]
     | {common_name: $mapping.system_user, role: $mapping.role, database: .}]
  | unique;

# The Kubernetes and k3s controllers, which create pods and other objects
# from objects that other subjects write.
def controllers:
  ["system:kube-controller-manager", "k3s-cloud-controller-manager"]
  + (["clusterrole-aggregation-controller", "cronjob-controller", "daemon-set-controller", "deployment-controller",
      "endpoint-controller", "endpointslice-controller", "endpointslicemirroring-controller",
      "generic-garbage-collector", "job-controller", "legacy-service-account-token-cleaner",
      "local-path-provisioner-service-account", "namespace-controller", "persistent-volume-binder",
      "replicaset-controller", "replication-controller", "resourcequota-controller", "root-ca-cert-publisher",
      "statefulset-controller"]
     | map("system:serviceaccount:kube-system:\(.)"));

# k3s installs Traefik with a Helm job per HelmChart, whose ServiceAccount
# k3s binds to cluster-admin.
def helm_install_jobs: ["helm-traefik", "helm-traefik-crd"] | map("system:serviceaccount:kube-system:\(.)");

# The subjects that may hold the rights of the kubernetes section:
# system:masters, the operator, the plugin, the instances, the API server,
# cert-manager and its cainjector, the controllers and k3s's Helm install
# jobs. The account names are arguments so the violation tests can give
# their own; evidence.sh and desired.sh give operator_account and plugin_account.
def allowed_subjects($operator_account; $plugin_account):
  ["group:system:masters",
   "system:serviceaccount:\(.network.operatorNamespace):\($operator_account)",
   "system:serviceaccount:\(.network.operatorNamespace):\($plugin_account)",
   "system:serviceaccount:\(.cluster.namespace):\(.cluster.name)",
   "kube-apiserver",
   "system:serviceaccount:\(cert_manager_namespace):cert-manager",
   "system:serviceaccount:\(cert_manager_namespace):cert-manager-cainjector"] + controllers + helm_install_jobs;

# Also allowed to read the Secrets of the cluster's namespace: Traefik reads
# Secrets in every namespace for the TLS certificates of the routes it serves.
def secret_readers: ["system:serviceaccount:kube-system:traefik"];

# The subjects that may create certificates.
def certificate_subjects:
  ["group:system:masters", "system:serviceaccount:\(cert_manager_namespace):cert-manager"] + controllers + helm_install_jobs;

# The namespaces where the operator and the plugin may read Secrets.
def secret_namespaces: [.network.operatorNamespace, .cluster.namespace];
