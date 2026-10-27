# Selects the first hostssl cert database and role as application login targets.
# Usage: jq -r -f application.jq < cluster.json
# Exit: 0 with a database/role pair or no output, nonzero for invalid input.
.spec.postgresql.pg_hba // []
| map([scan("\\S+")])
| map(select(.[0] == "hostssl" and .[4] == "cert"))
| first // empty
| "\(.[1]) \(.[2])"
