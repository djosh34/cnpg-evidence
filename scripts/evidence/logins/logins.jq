# The pg_hba and pg_ident lines as {number, line}: one list when every
# instance has the same lines, else one list per instance. PostgreSQL reads
# every line of a pg_ident map, so pg_ident lines count as the same in any
# order. ident holds the pg_ident mappings of every instance, for the
# certificate login table.
#
# Input: {<pod>: {pg_hba, pg_ident}} from rules.sql.
# Output: {pg_hba, pg_ident, ident: [{map, system_user, role}]}

# $same gives what must be equal for two instances to have the same lines.
def per_instance_when_different(same):
  if (map(same) | unique | length) <= 1 then (to_entries | .[0].value // [])
  else . end;

{
  pg_hba: (map_values([.pg_hba[] | {number, line}]) | per_instance_when_different(.)),
  pg_ident: (map_values([.pg_ident[] | {number, line}]) | per_instance_when_different(map(.line) | sort)),
  ident: ([.[].pg_ident[] | select(.error == null) | {map, system_user, role}] | unique)
}
