#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

# Facts with one violation in each of two sections; the other sections are clean.
input=$(cat <<'EOF2'
{
  "values": {"cluster": {"name": "pg", "namespace": "databases", "instances": 1}, "caSecret": "client-ca",
             "network": {"operatorNamespace": "cnpg-system", "otelNamespace": "otel"},
             "replication": {"commonName": "pg-replication"}, "databases": []},
  "expected_ca": [{"name": "CN=example-ca", "sha256_fingerprint": "2E:18"}],
  "operator_account": "op", "plugin_account": "plug",
  "facts": {
    "postgres": {"superusers":["postgres"],"can_create_roles":["postgres"],"can_create_databases":["postgres"],"can_replicate":["postgres","streaming_replica"],"can_bypass_row_security":["postgres"],"can_run_server_programs":["postgres"],"can_read_server_files":["postgres","streaming_replica"],"can_write_server_files":["postgres"],"can_read_all_data":["postgres"],"can_write_all_data":["postgres"],"have_password":["postgres"],"can_log_in":["cnpg_metrics_exporter","postgres","streaming_replica"],"roles":["cnpg_metrics_exporter","postgres","streaming_replica"]},
    "databases": {
      "postgres": {"owner":"postgres","logins":{"cnpg_metrics_exporter":{"os_users":["postgres"]},"postgres":{"os_users":["postgres"]},"streaming_replica":{"common_names":["pg-replication","streaming_replica"]}}},
      "template0": {"owner":"postgres","allows_connections":false},
      "template1": {"owner":"postgres","logins":{"cnpg_metrics_exporter":{"os_users":["postgres"]},"postgres":{"os_users":["postgres"]}}},
      "replication": {"logins":{"streaming_replica":{"common_names":["pg-replication","streaming_replica"]}}}
    },
    "tls": {"pg-1": {"postgresql": "TLSv1.3", "metrics": "TLSv1.3"}},
    "client_ca": {"secret":"client-ca","certificates":[{"name":"CN=example-ca","sha256_fingerprint":"2E:18"}]},
    "network_policy": {"pg-1": {"outside":[5432],"other nodes":[5432],"own node":["all"],"loadbalancer":[5432],"pg pods":[5432,8000],"cnpg-system operator":[8000],"otel":[9187],"other namespaces":[]}},
    "kubernetes": {"namespaces":{},"request_certificates":[],"proxy_to_nodes":[],"impersonate":[],"bind_or_escalate_roles":[],"change_webhooks":[],"can_open_node_ports":[],"operator_reads_secrets_in":[],"plugin_reads_secrets_in":[]},
    "pods_sharing_host_uids": ["pg-1"],
    "host_network_pods_that_can_bind_low_ports": [],
    "details": {"instances":["pg-1"],"pg_hba":[],"pg_ident":[],"pg_hba_not_understood":[],"pg_ident_not_understood":[]}
  }
}
EOF2
)

same "the sentences of every section, in order" \
  '["rule 2: role postgres has a password", "rule 6: pod pg-1 shares host uids"]' \
  "$(bash "$here/violations.sh" <<<"$input")"

if bash "$here/violations.sh" <<<'{"facts": {}}' >/dev/null 2>&1; then
  fail "facts it cannot read fail"
else
  pass "facts it cannot read fail"
fi

finish
