# Rules 6 and 7 for the kubernetes section: only the allowed subjects hold a
# right that equals PostgreSQL superuser in the cluster's namespace, create
# certificates, write routes, run pods or can become cluster-admin, and the
# operator and the plugin read Secrets only in their own and the cluster's
# namespace.
#
# Input: {facts, values, granted_by, operator_account, plugin_account}, granted_by
# from kubernetes/kubernetes.jq and optional. Output: a list of sentences.

include "common";
include "expected";

.facts.kubernetes as $k
| .operator_account as $operator_account
| .plugin_account as $plugin_account
# The subjects that may hold these rights are in expected.jq.
| (.values | allowed_subjects($operator_account; $plugin_account)) as $allowed
| (.values | secret_namespaces) as $secret_namespaces
| .values.cluster.namespace as $namespace

# Each sentence ends with the reasons the API server gave, which name the
# bindings that allowed the right.
| (.granted_by // {}) as $granted_by
| def because($key; $holder):
    [$granted_by[$key][$holder]? // [] | .[] | ltrimstr("RBAC: ") | select(. != "")]
    | if . == [] then "" else " (\(join("; ")))" end;

  def not_allowed($key; $allowed_subjects; $says):
    $k[$key] // [] | extra($allowed_subjects) | "rule 7: \(.) can \($says)\(because($key; .))";

  def reads_secrets($key; $who):
    $k[$key] | extra($secret_namespaces)
    | "rule 6: \($who) can read secrets in \(.)\(because($key; .))";

  [
    not_allowed("superuser_in_cluster_namespace"; $allowed + secret_readers;
                "get PostgreSQL superuser through rights in \($namespace)"),
    not_allowed("create_certificates"; certificate_subjects; "create Certificates or CertificateRequests"),
    not_allowed("write_routes"; $allowed; "write Ingresses, IngressRoutes or IngressRouteTCPs"),
    not_allowed("run_pods"; $allowed; "run pods"),
    not_allowed("become_cluster_admin"; $allowed; "become cluster-admin"),
    reads_secrets("operator_reads_secrets_in"; "the operator"),
    reads_secrets("plugin_reads_secrets_in"; "the barman-cloud plugin")
  ]
