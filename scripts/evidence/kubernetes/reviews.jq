# One SubjectAccessReview per distinct question, all in one v1 List, so that
# a single kubectl call asks them all. The API server answers each as it
# would answer the subject itself, so the subject's groups are given:
# a ServiceAccount is in system:serviceaccounts, the group of its namespace
# and system:authenticated; a user in system:authenticated; a group is asked
# as a probe user in that group and system:authenticated.
#
# Input: the needs from needs.jq, slurped. Output: a v1 List.

def subject_spec:
  if startswith("group:") then
    {user: "evidence-group-probe", groups: [ltrimstr("group:"), "system:authenticated"]}
  elif startswith("system:serviceaccount:") then
    {user: ., groups: ["system:serviceaccounts", "system:serviceaccounts:\(split(":")[2])", "system:authenticated"]}
  else {user: ., groups: ["system:authenticated"]}
  end;

# "clusters.postgresql.cnpg.io/pg" is resource clusters in group
# postgresql.cnpg.io, object pg; "-" is no subresource or every namespace.
def resource_attributes:
  (.resource | split("/")) as $parts
  | ($parts[0] | split(".")) as $type
  | {verb, resource: $type[0], group: ($type[1:] | join("."))}
    + if $parts[1:] != [] then {name: ($parts[1:] | join("/"))} else {} end
    + if .subresource != "-" then {subresource} else {} end
    + if .namespace != "-" then {namespace} else {} end;

{
  apiVersion: "v1",
  kind: "List",
  items: [
    [.[] | .ask + {subject}] | unique | .[]
    | {apiVersion: "authorization.k8s.io/v1", kind: "SubjectAccessReview",
       spec: ((.subject | subject_spec) + {resourceAttributes: resource_attributes})}
  ]
}
