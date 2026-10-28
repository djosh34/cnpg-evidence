# Rule 1 for the login rules: every instance has exactly the expected pg_hba
# lines in the expected order, and exactly the expected pg_ident lines in
# any order.
#
# Input: {facts, values}. Output: a list of sentences.

include "common";
include "expected";

.facts.details as $details
| (.values | expected_pg_hba) as $expected_hba
| (.values | expected_pg_ident) as $expected_ident
| [
    if $details.pg_hba | type == "object" then "rule 1: pg_hba differs between instances"
    else
      ($details.pg_hba | map(.line)) as $actual
      | range([$actual, $expected_hba] | map(length) | max) as $i
      | ($i + 1) as $place
      | if $actual[$i] == $expected_hba[$i] then empty
        elif $actual[$i] == null then "rule 1: pg_hba lacks line \($place): \($expected_hba[$i])"
        elif $expected_hba[$i] == null then "rule 1: pg_hba has an extra line \($place): \($actual[$i])"
        else "rule 1: pg_hba line \($place) is \"\($actual[$i])\", not \"\($expected_hba[$i])\""
        end
    end,
    if $details.pg_ident | type == "object" then "rule 1: pg_ident differs between instances"
    else
      ($details.pg_ident | map(.line)) as $actual
      | ($actual | extra($expected_ident) | "rule 1: pg_ident has an extra line: \(.)"),
        ($expected_ident | missing($actual) | "rule 1: pg_ident lacks the line: \(.)")
    end
  ]
