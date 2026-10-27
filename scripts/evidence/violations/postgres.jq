# Rules 1 to 4 for the postgres section: which roles hold which right, which
# have a password, which exist and which can log in. CNPG's own roles: postgres is the
# superuser, streaming_replica replicates and reads files for pg_rewind,
# cnpg_metrics_exporter logs in for metrics.
#
# Input: {facts, values}. Output: a list of sentences.

include "common";

.facts.postgres as $postgres
| {
    superusers: {expected: ["postgres"], says: "is a superuser"},
    can_create_roles: {expected: ["postgres"], says: "can create roles"},
    can_create_databases: {expected: ["postgres"], says: "can create databases"},
    can_replicate: {expected: ["postgres", "streaming_replica"], says: "can replicate"},
    can_bypass_row_security: {expected: ["postgres"], says: "can bypass row security"},
    can_run_server_programs: {expected: ["postgres"], says: "can run programs on the server"},
    can_read_server_files: {expected: ["postgres", "streaming_replica"], says: "can read server files"},
    can_write_server_files: {expected: ["postgres"], says: "can write server files"},
    can_read_all_data: {expected: ["postgres"], says: "can read all data"},
    can_write_all_data: {expected: ["postgres"], says: "can write all data"}
  } as $role_rights
| (["postgres", "streaming_replica", "cnpg_metrics_exporter"] + [.values.databases[].role]) as $expected_roles
| [
    ($role_rights | to_entries[]
     | .key as $list | .value as $right
     | ($postgres[$list] | extra($right.expected) | "rule 3: role \(.) \($right.says)"),
       ($right.expected | missing($postgres[$list]) | "rule 3: role \(.) is missing from \($list)")),
    ($postgres.have_password[] | "rule 2: role \(.) has a password"),
    ($postgres.roles | extra($expected_roles)
     | if . == "app" then "rule 4: role app exists" else "rule 1: role \(.) exists and is not in the values" end),
    ($expected_roles | missing($postgres.roles) | "rule 1: role \(.) does not exist"),
    ($expected_roles | missing($postgres.can_log_in) | . as $role | select($postgres.roles | includes($role)) | "rule 1: role \(.) cannot log in")
  ]
