# Rules 1 to 4 for the postgres section: which roles hold which right, which
# have a password, which exist and which can log in, and which databases
# exist. The expected roles of
# each right are in expected.jq.
#
# Input: {facts, values}. Output: a list of sentences.

include "common";
include "expected";

.facts.postgres as $postgres
| {
    superusers: "is a superuser",
    can_create_roles: "can create roles",
    can_create_databases: "can create databases",
    can_replicate: "can replicate",
    can_bypass_row_security: "can bypass row security",
    can_run_server_programs: "can run programs on the server",
    can_read_server_files: "can read server files",
    can_write_server_files: "can write server files",
    can_read_all_data: "can read all data",
    can_write_all_data: "can write all data",
    can_read_ident_mappings: "can read pg_ident"
  } as $says
| (.values | expected_roles) as $expected_roles
| (.values | expected_databases) as $expected_databases
| [
    (role_rights | to_entries[]
     | .key as $list | .value as $expected
     | ($postgres[$list] | extra($expected) | "rule 3: role \(.) \($says[$list])"),
       ($expected | missing($postgres[$list]) | "rule 3: role \(.) is missing from \($list)")),
    ($postgres.have_password[] | "rule 2: role \(.) has a password"),
    ($postgres.roles | extra($expected_roles)
     | if . == "app" then "rule 4: role app exists" else "rule 1: role \(.) exists and is not in the values" end),
    ($expected_roles | missing($postgres.roles) | "rule 1: role \(.) does not exist"),
    ($expected_roles | missing($postgres.can_log_in) | . as $role | select($postgres.roles | includes($role)) | "rule 1: role \(.) cannot log in"),
    ($postgres.databases | extra($expected_databases)
     | if . == "app" then "rule 4: database app exists" else "rule 1: database \(.) exists and is not in the values" end),
    ($expected_databases | missing($postgres.databases) | "rule 1: database \(.) does not exist")
  ]
