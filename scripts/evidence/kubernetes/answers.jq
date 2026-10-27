# The answers to the SubjectAccessReviews from reviews.jq, as the questions
# of needs.jq: subject, verb, resource, subresource and namespace as asked,
# allowed, and the reason the API server gives, which names the binding
# that allowed it.
#
# Input: the reviews as kubectl prints them, slurped. Output: one answer per line.

.[]
| .spec as $spec
| $spec.resourceAttributes as $attributes
| {
    subject: (if $spec.user == "evidence-group-probe" and ($spec.groups | length) == 2
              then "group:\($spec.groups[0])" else $spec.user end),
    verb: $attributes.verb,
    resource: ($attributes.resource
               + if ($attributes.group // "") != "" then ".\($attributes.group)" else "" end
               + if ($attributes.name // "") != "" then "/\($attributes.name)" else "" end),
    subresource: ($attributes.subresource // "-"),
    namespace: ($attributes.namespace // "-"),
    allowed: (.status.allowed == true),
    reason: (.status.reason // "")
  }
