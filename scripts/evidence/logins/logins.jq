# The pg_hba and pg_ident lines as {number, line}: one list when every
# instance has the same lines, else one list per instance. ident holds the
# pg_ident mappings of every instance, for the certificate login table.
#
# Input: {<pod>: {pg_hba, pg_ident}} from rules.sql.
# Output: {pg_hba, pg_ident, ident: [{map, system_user, role}]}

def per_instance_when_different:
  if (to_entries | map(.value) | unique | length) <= 1 then (to_entries | .[0].value // [])
  else . end;

{
  pg_hba: (map_values([.pg_hba[] | {number, line}]) | per_instance_when_different),
  pg_ident: (map_values([.pg_ident[] | {number, line}]) | per_instance_when_different),
  ident: ([.[].pg_ident[] | select(.error == null) | {map, system_user, role}] | unique)
}
