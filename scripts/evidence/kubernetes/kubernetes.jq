# The kubernetes section: per right, the subjects the API server said yes for,
# and in granted_by the same shape with each subject's reasons, which name
# the bindings that allowed it.
#
# Input: {needs (from needs.jq), answers (from answers.jq), namespace,
#         component_namespaces, not_served}

def key: [.subject, .verb, .resource, .subresource, .namespace] | join("\t");

(.answers | map({key: key, value: .}) | from_entries) as $answers
| [.needs[]
   | (.ask + {subject} | key) as $question
   | (if $answers | has($question) then $answers[$question] else error("no answer for \($question)") end) as $answer
   | select($answer.allowed)
   | {right, in, subject, reason: $answer.reason}] as $granted

# A list of who holds a right, or with $mode "reasons" a map from each of
# them to the reasons. $by is "subject", or "in" for the namespaces a right
# holds in.
| def leaf($mode; $entries; $by):
    if $mode == "holders" then [$entries[][$by]] | unique
    else $entries | group_by(.[$by]) | map({key: .[0][$by], value: (map(.reason) | unique)}) | from_entries
    end;
  def holders($mode; $right): leaf($mode; [$granted[] | select(.right == $right)]; "subject");
  def holders_in($mode; $right; $namespaces):
    leaf($mode; [$granted[] | select(.right == $right and (.in | IN($namespaces[])))]; "subject");
  def any_of($mode; $rights): leaf($mode; [$granted[] | select(.right | IN($rights[]))]; "subject");
  def namespaces_of($mode; $right): leaf($mode; [$granted[] | select(.right == $right)]; "in");

  # The namespaces whose ServiceAccounts a subject's pods could run as.
  def account_namespaces($all):
    if startswith("system:serviceaccount:") then split(":")[2]
    elif startswith("group:system:serviceaccounts:") then ltrimstr("group:system:serviceaccounts:")
    elif IN("group:system:serviceaccounts", "group:system:authenticated") then $all[]
    else empty
    end;

. as $input
| ([.needs[].in | select(. != "")] | unique) as $all_namespaces

# Rights with a name after the prefix, such as "read_secret pg-replication":
# per name, its holders in that namespace.
| def named_in($mode; $prefix; $namespace):
    [$input.needs[] | select(.in == $namespace) | .right | select(startswith($prefix))] | unique
    | map({key: ltrimstr($prefix), value: holders_in($mode; .; [$namespace])}) | from_entries;

  def rights_in($mode; $namespace):
    {
      exec_into_pods: holders_in($mode; "exec_into_pods"; [$namespace]),
      change_pods: holders_in($mode; "change_pods"; [$namespace]),
      run_pods: holders_in($mode; "run_pods"; [$namespace]),
      read_secret: named_in($mode; "read_secret "; $namespace),
      write_secret: named_in($mode; "write_secret "; $namespace)
    }
    + if $namespace == $input.namespace then
        {create_pg_tokens: holders_in($mode; "create_pg_tokens"; [$namespace]), change: named_in($mode; "change "; $namespace)}
      else {} end;

  ([holders("holders"; "create_certificates")[] | account_namespaces($all_namespaces)] | unique) as $certificate_account_namespaces
| def section($mode):
    {
      namespaces: ([$input.component_namespaces[] | {key: ., value: rights_in($mode; .)}] | from_entries),
      request_certificates:
        leaf($mode; [$granted[] | select(.right == "create_certificates"
                                         or (.right == "run_pods" and (.in | IN($certificate_account_namespaces[]))))];
             "subject"),
      proxy_to_nodes: holders($mode; "proxy_to_nodes"),
      impersonate: holders($mode; "impersonate"),
      bind_or_escalate_roles: holders($mode; "bind_or_escalate_roles"),
      change_webhooks: holders($mode; "change_webhooks"),
      can_open_node_ports: any_of($mode; ["run_pods", "change_services", "change_ingresses"]),
      operator_reads_secrets_in: namespaces_of($mode; "operator_reads_secrets_in"),
      plugin_reads_secrets_in: namespaces_of($mode; "plugin_reads_secrets_in")
    };

  section("holders")
  + if .not_served == [] then {} else {not_served: .not_served} end
  + {granted_by: section("reasons")}
