#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

logins() { jq -f "$here/logins.jq"; }

# CNPG's fixed lines and one client database, as the samples render.
input=$(cat <<'EOF'
{
  "instances": {
    "pg-1": {
      "pg_hba": [
        {"number": 1, "line": "local all all peer map=local", "type": "local", "databases": ["all"], "users": ["all"], "address": null, "method": "peer", "options": ["map=local"], "error": null},
        {"number": 2, "line": "hostssl replication streaming_replica all cert map=cnpg_streaming_replica", "type": "hostssl", "databases": ["replication"], "users": ["streaming_replica"], "address": "all", "method": "cert", "options": ["map=cnpg_streaming_replica"], "error": null},
        {"number": 3, "line": "hostssl orders orders all cert map=clients", "type": "hostssl", "databases": ["orders"], "users": ["orders"], "address": "all", "method": "cert", "options": ["map=clients", "clientcert=verify-full"], "error": null},
        {"number": 4, "line": "host all all all reject", "type": "host", "databases": ["all"], "users": ["all"], "address": "all", "method": "reject", "options": [], "error": null},
        {"number": 5, "line": "host all all all scram-sha-256", "type": "host", "databases": ["all"], "users": ["all"], "address": "all", "method": "scram-sha-256", "options": [], "error": null}
      ],
      "pg_ident": [
        {"number": 1, "line": "local postgres postgres", "map": "local", "system_user": "postgres", "role": "postgres", "error": null},
        {"number": 2, "line": "cnpg_streaming_replica pg-replication streaming_replica", "map": "cnpg_streaming_replica", "system_user": "pg-replication", "role": "streaming_replica", "error": null},
        {"number": 3, "line": "clients orders-app.test orders", "map": "clients", "system_user": "orders-app.test", "role": "orders", "error": null}
      ]
    }
  },
  "catalog": {
    "roles": [
      {"name": "orders", "member_of": ["orders"]},
      {"name": "postgres", "member_of": ["postgres"]},
      {"name": "streaming_replica", "member_of": ["streaming_replica"]}
    ],
    "databases": [
      {"name": "orders", "owner": "orders", "allows_connections": true, "connect": ["PUBLIC", "orders"]},
      {"name": "template0", "owner": "postgres", "allows_connections": false}
    ]
  }
}
EOF
)

expected=$(cat <<'EOF'
{
  "databases": {
    "orders": {
      "owner": "orders",
      "connect": ["PUBLIC", "orders"],
      "logins": {
        "orders": {"common_names": ["orders-app.test"]},
        "postgres": {"os_users": ["postgres"]}
      }
    },
    "template0": {"owner": "postgres", "allows_connections": false},
    "replication": {
      "logins": {
        "streaming_replica": {"common_names": ["pg-replication"]}
      }
    }
  },
  "details": {
    "pg_hba": [
      {"number": 1, "line": "local all all peer map=local"},
      {"number": 2, "line": "hostssl replication streaming_replica all cert map=cnpg_streaming_replica"},
      {"number": 3, "line": "hostssl orders orders all cert map=clients"},
      {"number": 4, "line": "host all all all reject"},
      {"number": 5, "line": "host all all all scram-sha-256"}
    ],
    "pg_ident": [
      {"number": 1, "line": "local postgres postgres"},
      {"number": 2, "line": "cnpg_streaming_replica pg-replication streaming_replica"},
      {"number": 3, "line": "clients orders-app.test orders"}
    ],
    "pg_hba_not_understood": [],
    "pg_ident_not_understood": []
  }
}
EOF
)
same "the scram line after the reject never applies" "$expected" "$(logins <<<"$input")"

# A password line for one network before the reject applies to that network.
input_password=$(jq '.instances["pg-1"].pg_hba |= .[:3] + [
  {"line": "host orders all 10.0.0.0 255.0.0.0 scram-sha-256", "type": "host", "databases": ["orders"], "users": ["all"], "address": "10.0.0.0", "method": "scram-sha-256", "options": [], "error": null}
] + .[3:]' <<<"$input")
expected=$(cat <<'EOF'
{
  "orders": {"common_names": ["orders-app.test"], "password": true},
  "postgres": {"os_users": ["postgres"], "password": true},
  "streaming_replica": {"password": true}
}
EOF
)
same "a password line before the reject is a password path" \
  "$expected" "$(logins <<<"$input_password" | jq .databases.orders.logins)"

# trust for members of a group, and a cert line without a map.
input_group=$(jq '
  .instances["pg-1"].pg_hba |= [
    {"line": "hostssl orders +readers all trust", "type": "hostssl", "databases": ["orders"], "users": ["+readers"], "address": "all", "method": "trust", "options": [], "error": null},
    {"line": "hostssl all all all cert", "type": "hostssl", "databases": ["all"], "users": ["all"], "address": "all", "method": "cert", "options": [], "error": null}
  ]
  | .catalog.roles[0].member_of += ["readers"]' <<<"$input")
expected=$(cat <<'EOF'
{
  "orders": {"no_authentication": true},
  "postgres": {"common_names": ["postgres"]},
  "streaming_replica": {"common_names": ["streaming_replica"]}
}
EOF
)
same "+role matches members, cert without a map wants the role name" \
  "$expected" "$(logins <<<"$input_group" | jq .databases.orders.logins)"

# A line that cannot be read is listed and skipped, so later lines still apply.
input_unknown=$(jq '.instances["pg-1"].pg_hba |= [
  {"line": "host all all all ldap ldapserver=x", "type": "host", "databases": ["all"], "users": ["all"], "address": "all", "method": "ldap", "options": ["ldapserver=x"], "error": null},
  {"line": "hostssl /^o all all cert", "type": "hostssl", "databases": ["/^o"], "users": ["all"], "address": "all", "method": "cert", "options": [], "error": null},
  {"line": "error: bad line", "type": null, "databases": [], "users": [], "address": null, "method": null, "options": [], "error": "bad line"}
] + .' <<<"$input")
expected=$(cat <<'EOF'
["error: bad line", "host all all all ldap ldapserver=x", "hostssl /^o all all cert"]
EOF
)
same "lines it cannot read are listed" \
  "$expected" "$(logins <<<"$input_unknown" | jq .details.pg_hba_not_understood)"
same "lines it cannot read do not hide later lines" \
  "$(logins <<<"$input" | jq .databases)" "$(logins <<<"$input_unknown" | jq .databases)"

# Instances that differ: the lines per instance, the logins of both.
input_two=$(jq '.instances["pg-2"] = (.instances["pg-1"] | .pg_ident += [
  {"number": 4, "line": "clients other.test orders", "map": "clients", "system_user": "other.test", "role": "orders", "error": null}
])' <<<"$input")
expected=$(cat <<'EOF'
{
  "logins": {"common_names": ["orders-app.test", "other.test"]},
  "pg_ident": {
    "pg-1": [
      {"number": 1, "line": "local postgres postgres"},
      {"number": 2, "line": "cnpg_streaming_replica pg-replication streaming_replica"},
      {"number": 3, "line": "clients orders-app.test orders"}
    ],
    "pg-2": [
      {"number": 1, "line": "local postgres postgres"},
      {"number": 2, "line": "cnpg_streaming_replica pg-replication streaming_replica"},
      {"number": 3, "line": "clients orders-app.test orders"},
      {"number": 4, "line": "clients other.test orders"}
    ]
  }
}
EOF
)
same "different instances: lines per instance, logins of all" \
  "$expected" "$(logins <<<"$input_two" | jq '{logins: .databases.orders.logins.orders, pg_ident: .details.pg_ident}')"

# A moved line keeps its text but not its number.
input_moved=$(jq '.instances["pg-1"].pg_hba |= ([.[0], .[2], .[1], .[3], .[4]] | to_entries | map(.value.number = .key + 1 | .value))' <<<"$input")
expected=$(cat <<'EOF'
[
  {"number": 1, "line": "local all all peer map=local"},
  {"number": 2, "line": "hostssl orders orders all cert map=clients"},
  {"number": 3, "line": "hostssl replication streaming_replica all cert map=cnpg_streaming_replica"},
  {"number": 4, "line": "host all all all reject"},
  {"number": 5, "line": "host all all all scram-sha-256"}
]
EOF
)
same "a moved line carries its new number" "$expected" "$(logins <<<"$input_moved" | jq .details.pg_hba)"

finish
