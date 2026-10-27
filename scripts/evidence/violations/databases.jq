# Rules 1, 2 and 4 for the databases section: every database from the values
# and CNPG's own, owned by the right role, reached only by the expected
# logins, and pg_hba and pg_ident the same on every instance and readable.
#
# Input: {facts, values}. Output: a list of sentences.

include "common";
include "expected";

.facts as $facts
| (.values | expected_databases) as $expected_databases
| [$facts.databases[].logins[]?.common_names[]?] as $all_common_names

| def where($name): if $name == "replication" then "physical replication" else "database \($name)" end;

  def login_violations($name; $expected; $actual):
    ($actual | keys_unsorted[]) as $role
    | ($expected[$role] // {}) as $want
    | $actual[$role] as $got
    | (($got.common_names // []) | extra($want.common_names // [])
       | "rule 1: \(where($name)): role \($role) logs in with common name \(.)"),
      (($got.os_users // []) | extra($want.os_users // [])
       | "rule 1: \(where($name)): role \($role) logs in as OS user \(.) over the pod socket"),
      (if $got.password and ($want.password | not) then "rule 2: \(where($name)): role \($role) can log in with a password" else empty end),
      (if $got.no_authentication then "rule 2: \(where($name)): role \($role) logs in without authentication" else empty end);

  def missing_login_violations($name; $expected; $actual):
    ($expected | keys_unsorted[]) as $role
    | ($actual[$role] // {}) as $got
    | (($expected[$role].common_names // []) | missing($got.common_names // [])
       | . as $common_name
       | if $all_common_names | includes($common_name) | not then "rule 1: common name \(.) maps to no role"
         else "rule 1: \(where($name)): common name \(.) does not log in as \($role)" end),
      (($expected[$role].os_users // []) | missing($got.os_users // [])
       | "rule 1: \(where($name)): role \($role) does not log in as OS user \(.)");

  [
    ($facts.databases | keys_unsorted[] | . as $name | select($expected_databases | has($name) | not)
     | if . == "app" then "rule 4: database app exists" else "rule 1: database \(.) exists and is not in the values" end),
    ($expected_databases | to_entries[]
     | .key as $name | .value as $expected | $facts.databases[$name] as $actual
     | if $actual == null then "rule 1: database \($name) does not exist"
       else
         (if $expected.owner != $actual.owner then "rule 1: database \($name) is owned by \($actual.owner), not \($expected.owner)" else empty end),
         (if $expected.allows_connections == false and $actual.allows_connections != false then "rule 1: database \($name) allows connections"
          elif $expected.allows_connections != false and $actual.allows_connections == false then "rule 1: database \($name) allows no connections"
          else empty end),
         login_violations($name; $expected.logins // {}; $actual.logins // {}),
         missing_login_violations($name; $expected.logins // {}; $actual.logins // {})
       end),
    (if $facts.details.pg_hba | type == "object" then "rule 1: pg_hba differs between instances" else empty end),
    (if $facts.details.pg_ident | type == "object" then "rule 1: pg_ident differs between instances" else empty end),
    ($facts.details.pg_hba_not_understood[] | "rule 1: pg_hba line cannot be read: \(.)"),
    ($facts.details.pg_ident_not_understood[] | "rule 1: pg_ident line cannot be read: \(.)")
  ]
