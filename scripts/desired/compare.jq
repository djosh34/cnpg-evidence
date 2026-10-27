# The literal differences between a desired and an actual document of the
# same source. A difference is not a failed check: the scripts' own checks
# stay the verdict.
#
# Each difference is {path, extra} for a value only the actual document has,
# or {path, missing} for one only the desired document has. A scalar that
# differs gives both at its path. path names object keys and, in a list of
# rows, the row's identity.
#
# - Skipped: the top-level kind, source, collected_at, cluster, node, status
#   and violations; details.primary and details.instances; every raw key;
#   and every top-level section the desired document lacks, such as software.
# - {"allowed": [...]} in the desired document is an allowed set: each actual
#   member it lacks is extra, a member the actual list lacks is no difference,
#   and so is an absent list.
# - A "*" key in a desired map stands for every actual key the map does not
#   name: instance pods and Secrets, whose names only a live cluster knows.
# - Lists are rows, compared by identity: the row's id or probe, else the
#   whole row without raw. An actual-only row is extra, a desired-only row is
#   missing, and rows with the same id or probe are compared key by key.
#   Order does not count; pg_hba and pg_ident rows carry their number.
#
# Usage: jq -n --slurpfile desired FILE --slurpfile actual FILE -f compare.jq

def skipped_top: ["kind", "source", "collected_at", "cluster", "node", "status", "violations"];
def skipped_paths: [["details", "primary"], ["details", "instances"]];

def allowed_set: type == "object" and keys == ["allowed"] and (.allowed | type == "array");

def identity:
  if type != "object" then .
  elif has("id") then .id
  elif has("probe") then .probe
  else del(.raw)
  end;

def keyed: type == "object" and (has("id") or has("probe"));

def without_raw: if type == "object" then del(.raw) else . end;

def differences($path; $desired; $actual):
  if $desired | allowed_set then
    if ($actual | type) == "array" then ($actual - $desired.allowed | unique[] | {path: $path, extra: .})
    else {path: $path, extra: $actual}
    end
  elif ($desired | type) == "object" and ($actual | type) == "object" then
    (($actual | keys_unsorted[]) as $key
     | ($path + [$key]) as $at
     | select($key != "raw" and (skipped_paths | index([$at]) | not))
     | if $desired | has($key) then differences($at; $desired[$key]; $actual[$key])
       elif $desired | has("*") then differences($at; $desired["*"]; $actual[$key])
       else {path: $at, extra: $actual[$key]}
       end),
    (($desired | keys_unsorted[]) as $key
     | select($key != "*" and ($actual | has($key) | not) and ($desired[$key] | allowed_set | not))
     | {path: ($path + [$key]), missing: $desired[$key]})
  elif ($desired | type) == "array" and ($actual | type) == "array" then
    ($actual[] as $row
     | [$desired[] | select(identity == ($row | identity))] as $match
     | if $match == [] then {path: $path, extra: ($row | without_raw)}
       elif $row | keyed then differences($path + [$row | identity]; $match[0]; $row)
       else empty
       end),
    ($desired[] as $row
     | select(any($actual[]; identity == ($row | identity)) | not)
     | {path: $path, missing: $row})
  elif $desired == $actual then empty
  else {path: $path, extra: ($actual | without_raw)}, {path: $path, missing: $desired}
  end;

$desired[0] as $desired
| $actual[0] as $actual
| if $desired.kind != "desired" or $actual.kind != "actual" then error("compare a desired with an actual document")
  elif $desired.source != $actual.source then error("the documents come from \($desired.source) and \($actual.source)")
  else
    [
      ($actual | keys_unsorted[]
       | select(. as $key | (skipped_top | index([$key]) | not) and ($desired | has($key)))
       | differences([.]; $desired[.]; $actual[.])),
      ($desired | keys_unsorted[]
       | select(. as $key | (skipped_top | index([$key]) | not) and ($actual | has($key) | not))
       | {path: [.], missing: $desired[.]})
    ]
  end
