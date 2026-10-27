# Every subject named in a RoleBinding or ClusterRoleBinding, and per
# namespace the subjects its RoleBindings name. ServiceAccounts become
# system:serviceaccount:<namespace>:<name>, groups group:<name>, users stay
# their name.
#
# Input: a list of RoleBindings and ClusterRoleBindings.
# Output: {subjects, named_in: {<namespace>: [subject]}}

def subject_name($binding_namespace):
  if .kind == "ServiceAccount" then "system:serviceaccount:\(.namespace // $binding_namespace):\(.name)"
  elif .kind == "Group" then "group:\(.name)"
  else .name
  end;

[.[] | (.metadata.namespace // "") as $namespace | .subjects[]? | {namespace: $namespace, name: subject_name($namespace)}]
| {
    subjects: (map(.name) | unique),
    named_in: (map(select(.namespace != "")) | group_by(.namespace)
               | map({key: .[0].namespace, value: (map(.name) | unique)}) | from_entries)
  }
