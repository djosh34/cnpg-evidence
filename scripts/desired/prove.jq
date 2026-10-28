# The desired prove document: every probe of prove.sh, in its order, with
# the expected text the probe writes and the value it has when it passes.
# The application login is the first database of the values, as the
# sample chart writes its pg_hba line first. The probe for missing instances
# (uid-probes) appears only when it fails, so it is not here.
#
# Usage: jq --arg postgres_uid UID -f prove.jq <values

.databases[0] as {name: $database, role: $role}
| def probe($name; $expected; $value): {probe: $name, expected: $expected, value: $value, ok: true};
  def denied($name; $expected): probe($name; $expected; "denied");
  {
    kind: "desired",
    source: "prove",
    namespace: .cluster.namespace,
    cluster: .cluster.name,
    probes: [
      denied("password-tls"; "refused by pg_hba reject"),
      denied("password-no-tls"; "refused by pg_hba reject"),
      denied("tls-no-client-cert"; "refused, \($role) to \($database) needs a client certificate"),
      denied("replication-cert-as-\($role)"; "refused, the certificate CN does not map to \($role)"),
      denied("replication-cert-as-streaming_replica"; "refused by pg_hba reject for database \($database)"),
      probe("control-replication-cert"; "logs in as streaming_replica to postgres (CNPG's fixed line)"; "allowed"),
      probe("control-other-namespace"; "connected (Kubernetes API, the pod network works)"; "allowed"),
      (5432, 8000, 9187 | denied("other-namespace-\(.)"; "timeout or connection refused")),
      denied("other-namespace-lb"; "pg_hba refusal or no connection (connection refused or connect timeout)"),
      ("socket-proc-root", "token-proc-root", "environ", "socket-host-path", "token-host-path", "pgdata-host-path"
       | denied("uid-\($postgres_uid) \(.)"; "Permission denied")),
      denied("uid-mapped socket-host-path"; "Permission denied")
    ]
  }
