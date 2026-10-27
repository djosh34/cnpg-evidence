# The desired evidence document, in the shape of evidence.sh's output, from
# the expected values in scripts/evidence/violations/expected.jq.
#
# A list that is only an allowed set is {"allowed": [...]}: the actual list
# may hold any of these and lacks none of them. A map keyed by live names
# (instance pods, Secrets) has the one key "*", which stands for every key.
# The primary, the instance pods and the versions are runtime facts and not
# in the document.
#
# Usage: jq --slurpfile certificates FILE -L scripts/evidence/violations -f evidence.jq <values
#   certificates: the CA certificates of --ca, from client-ca/certificates.sh.

include "expected";

def allowed: {allowed: .};

def numbered: to_entries | map({number: (.key + 1), line: .value});

. as $values
| allowed_subjects(operator_account; plugin_account) as $allowed
| def rights_in($namespace):
    ($allowed + allowed_in($namespace) | allowed) as $here
    | {
        exec_into_pods: $here,
        change_pods: $here,
        run_pods: $here,
        read_secret: {"*": $here},
        write_secret: {"*": $here}
      }
      + if $namespace == $values.cluster.namespace then
          {
            create_pg_tokens: $here,
            change: ([
              "clusters", "databases", "databaseroles", "subscriptions", "poolers", "objectstores",
              "endpoints", "endpointslices", "networkpolicies"
            ] | map({key: ., value: $here}) | from_entries)
          }
        else {} end;
  {
    kind: "desired",
    source: "evidence",
    cluster: {name: .cluster.name, namespace: .cluster.namespace},
    postgres: (role_rights + {have_password: [], can_log_in: (expected_roles | sort), roles: (expected_roles | sort)}),
    databases: expected_databases,
    client_ca: {secret: .caSecret, certificates: $certificates[0]},
    tls: {"*": {postgresql: tls_minimum, metrics: tls_minimum}},
    network_policy: {"*": network_sources},
    kubernetes: {
      namespaces: (component_namespaces | map({key: ., value: rights_in(.)}) | from_entries),
      request_certificates: (certificate_subjects | allowed),
      proxy_to_nodes: ($allowed | allowed),
      impersonate: ($allowed | allowed),
      bind_or_escalate_roles: ($allowed | allowed),
      change_webhooks: ($allowed | allowed),
      can_open_node_ports: ($allowed | allowed),
      operator_reads_secrets_in: (secret_namespaces | allowed),
      plugin_reads_secrets_in: (secret_namespaces | allowed),
      not_served: (["ingressroutes.traefik.io"] | allowed)
    },
    pods_sharing_host_uids: [],
    host_network_pods_that_can_bind_low_ports: [],
    details: {
      pg_hba: (expected_pg_hba | numbered),
      pg_ident: (expected_pg_ident | numbered),
      pg_hba_not_understood: [],
      pg_ident_not_understood: []
    }
  }
