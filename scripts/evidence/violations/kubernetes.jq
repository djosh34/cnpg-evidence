# Rules 7 and 8 for the kubernetes section: only the allowed subjects hold a
# right that equals PostgreSQL superuser, in the namespaces of the cluster,
# the operator and cert-manager or anywhere, and the operator and the plugin
# read secrets only in their own and the cluster's namespace.
#
# Input: {facts, values, granted_by, operator_account, plugin_account}, granted_by
# from kubernetes/kubernetes.jq and optional. Output: a list of sentences.

include "common";
include "expected";

.values.cluster.name as $cluster
| .facts.kubernetes as $k
| .operator_account as $operator_account
| .plugin_account as $plugin_account
# The subjects that may hold these rights and that may request
# certificates are in expected.jq.
| (.values | allowed_subjects($operator_account; $plugin_account)) as $allowed
| certificate_subjects as $certificate_allowed
| (.values | secret_namespaces) as $secret_namespaces

# Each sentence ends with the reasons the API server gave, which name the
# bindings that allowed the right.
| (.granted_by // {}) as $granted_by
| def because($path; $holder):
    [$granted_by | getpath($path + [$holder])? // [] | .[] | ltrimstr("RBAC: ") | select(. != "")]
    | if . == [] then "" else " (\(join("; ")))" end;

  def not_allowed($path; $allowed_subjects; $says):
    $k | getpath($path) // [] | extra($allowed_subjects) | "rule 8: \(.) can \($says)\(because($path; .))";

  def secret_violations($rights; $allowed_subjects; $namespace):
    ($rights.read_secret | keys_unsorted[]
     | ["namespaces", $namespace, "read_secret", .] as $path
     | if . == "all (list)" then not_allowed($path; $allowed_subjects; "list secrets in \($namespace)")
       elif . == "all (watch)" then not_allowed($path; $allowed_subjects; "watch secrets in \($namespace)")
       else not_allowed($path; $allowed_subjects; "get secret \(.) in \($namespace)")
       end),
    ($rights.write_secret | keys_unsorted[]
     | ["namespaces", $namespace, "write_secret", .] as $path
     | if . == "all (create)" then not_allowed($path; $allowed_subjects; "create secrets in \($namespace)")
       else not_allowed($path; $allowed_subjects; "change secret \(.) in \($namespace)")
       end);

  def reads_secrets($key; $who):
    $k[$key] | extra($secret_namespaces)
    | "rule 7: \($who) can read secrets in \(.)\(because([$key]; .))";

  [
    ($k.namespaces | to_entries[]
     | .key as $in | .value as $rights
     | ($allowed + allowed_in($in)) as $allowed_here
     | not_allowed(["namespaces", $in, "exec_into_pods"]; $allowed_here; "exec into pods in \($in)"),
       not_allowed(["namespaces", $in, "change_pods"]; $allowed_here; "change pods in \($in)"),
       not_allowed(["namespaces", $in, "run_pods"]; $allowed_here; "create or change pods or workloads in \($in)"),
       secret_violations($rights; $allowed_here; $in),
       not_allowed(["namespaces", $in, "create_pg_tokens"]; $allowed_here; "create tokens for ServiceAccount \($cluster) in \($in)"),
       ($rights.change // {} | keys_unsorted[] | not_allowed(["namespaces", $in, "change", .]; $allowed_here; "change \(.) in \($in)"))),
    not_allowed(["request_certificates"]; $certificate_allowed; "request certificates"),
    not_allowed(["proxy_to_nodes"]; $allowed; "proxy to nodes"),
    not_allowed(["impersonate"]; $allowed; "impersonate users, groups or ServiceAccounts"),
    not_allowed(["bind_or_escalate_roles"]; $allowed; "bind or escalate roles"),
    not_allowed(["change_webhooks"]; $allowed; "change admission webhooks"),
    not_allowed(["can_open_node_ports"]; $allowed; "open ports on the nodes"),
    reads_secrets("operator_reads_secrets_in"; "the operator"),
    reads_secrets("plugin_reads_secrets_in"; "the barman-cloud plugin")
  ]
