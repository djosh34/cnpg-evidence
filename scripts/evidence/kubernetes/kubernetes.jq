# The kubernetes section: per right, the subjects the API server said yes for,
# and in granted_by the same shape with each subject's reasons, which name
# the bindings that allowed it. granted_by also lists in
# superuser_beyond_reading_secrets the subjects that hold a right of that row
# other than reading Secrets.
#
# Input: {needs (from needs.jq), answers (from answers.jq), not_served}

def key: [.subject, .verb, .resource, .subresource, .namespace] | join("\t");

(.answers | map({key: key, value: .}) | from_entries) as $answers
| [.needs[]
   | (.ask + {subject} | key) as $question
   | (if $answers | has($question) then $answers[$question] else error("no answer for \($question)") end) as $answer
   | select($answer.allowed)
   | {right, in, subject, secret_read, reason: $answer.reason}] as $granted

# A list of who holds a right, or with $mode "reasons" a map from each of
# them to the reasons. $by is "subject", or "in" for the namespaces a right
# holds in.
| def leaf($mode; $right; $by):
    [$granted[] | select(.right == $right)] as $entries
    | if $mode == "holders" then [$entries[][$by]] | unique
      else $entries | group_by(.[$by]) | map({key: .[0][$by], value: (map(.reason) | unique)}) | from_entries
      end;

  def section($mode):
    {
      superuser_in_cluster_namespace: leaf($mode; "superuser_in_cluster_namespace"; "subject"),
      create_certificates: leaf($mode; "create_certificates"; "subject"),
      write_routes: leaf($mode; "write_routes"; "subject"),
      run_pods: leaf($mode; "run_pods"; "subject"),
      become_cluster_admin: leaf($mode; "become_cluster_admin"; "subject"),
      operator_reads_secrets_in: leaf($mode; "operator_reads_secrets_in"; "in"),
      plugin_reads_secrets_in: leaf($mode; "plugin_reads_secrets_in"; "in")
    };

  section("holders")
  + if .not_served == [] then {} else {not_served: .not_served} end
  + {granted_by: (section("reasons") + {
      superuser_beyond_reading_secrets:
        ([$granted[] | select(.right == "superuser_in_cluster_namespace" and (.secret_read | not)) | .subject] | unique)
    })}
