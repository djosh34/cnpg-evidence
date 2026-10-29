#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

# Facts with one violation in each of two sections; the other sections are clean.
input=$(cat <<'EOF2'
{
  "values": {"cluster": {"name": "pg", "namespace": "databases", "instances": 1}, "caSecret": "client-ca",
             "rwLoadBalancer": {"name": "pg-rw-lb"}, "network": {"operatorNamespace": "cnpg-system"},
             "replication": {"commonName": "pg-replication"}, "databases": []},
  "expected_ca": [{"name": "CN=example-ca", "sha256_fingerprint": "2E:18"}],
  "operator_account": "op", "plugin_account": "plug",
  "facts": {
    "postgres": {"superusers":["postgres"],"can_create_roles":["postgres"],"can_create_databases":["postgres"],"can_replicate":["postgres","streaming_replica"],"can_bypass_row_security":["postgres"],"can_run_server_programs":["postgres"],"can_read_server_files":["postgres","streaming_replica"],"can_write_server_files":["postgres"],"can_read_all_data":["postgres"],"can_write_all_data":["postgres"],"can_read_ident_mappings":["cnpg_metrics_exporter","postgres"],"have_password":["postgres"],"can_log_in":["cnpg_metrics_exporter","postgres","streaming_replica"],"roles":["cnpg_metrics_exporter","postgres","streaming_replica"],"databases":["postgres","template0","template1"]},
    "tls": {"pg-1": {"postgresql": "TLSv1.3", "metrics": "TLSv1.3"}},
    "client_ca": {"secret":"client-ca","certificates":[{"name":"CN=example-ca","sha256_fingerprint":"2E:18"}]},
    "kubernetes": {"superuser_in_cluster_namespace":[],"create_certificates":[],"write_routes":[],"run_pods":[],"become_cluster_admin":[],"operator_reads_secrets_in":[],"plugin_reads_secrets_in":[]},
    "pods_sharing_host_uids": ["pg-1"],
    "details": {"instances":["pg-1"],
      "pg_hba":[{"number":1,"line":"local all cnpg_metrics_exporter peer map=cnpg_metrics_exporter"},{"number":2,"line":"local all all peer map=local"},
                {"number":3,"line":"hostssl postgres streaming_replica all cert map=cnpg_streaming_replica clientcert=verify-full"},
                {"number":4,"line":"hostssl replication streaming_replica all cert map=cnpg_streaming_replica clientcert=verify-full"},
                {"number":5,"line":"hostssl all cnpg_pooler_pgbouncer all cert map=cnpg_pooler_pgbouncer clientcert=verify-full"},
                {"number":6,"line":"host all all all reject"},{"number":7,"line":"host all all all scram-sha-256"}],
      "pg_ident":[{"number":1,"line":"local postgres postgres"},{"number":2,"line":"cnpg_streaming_replica streaming_replica streaming_replica"},
                  {"number":3,"line":"cnpg_pooler_pgbouncer cnpg_pooler_pgbouncer cnpg_pooler_pgbouncer"},
                  {"number":4,"line":"cnpg_metrics_exporter postgres cnpg_metrics_exporter"},
                  {"number":5,"line":"cnpg_streaming_replica pg-replication streaming_replica"}]}
  }
}
EOF2
)

same "the sentences of every section, in order" \
  '["rule 2: role postgres has a password", "rule 5: pod pg-1 shares host uids"]' \
  "$(bash "$here/violations.sh" <<<"$input")"

if bash "$here/violations.sh" <<<'{"facts": {}}' >/dev/null 2>&1; then
  fail "facts it cannot read fail"
else
  pass "facts it cannot read fail"
fi

finish
