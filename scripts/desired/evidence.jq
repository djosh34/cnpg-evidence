# The desired evidence document, in the shape of evidence.sh's output, from
# the expected values in scripts/evidence/violations/expected.jq.
#
# A list that is only an allowed set is {"allowed": [...]}: the actual list
# may hold any of these and lacks none of them. A map keyed by live names
# (instance pods) has the one key "*", which stands for every key.
# The primary, the instance pods and the versions are runtime facts and not
# in the document.
#
# Usage: jq --slurpfile certificates FILE -L scripts/evidence/violations -f evidence.jq <values
#   certificates: the CA certificates of --ca, from client-ca/certificates.sh.

include "expected";

def allowed: {allowed: .};

def numbered: to_entries | map({number: (.key + 1), line: .value});

allowed_subjects(operator_account; plugin_account) as $allowed
| {
    kind: "desired",
    source: "evidence",
    cluster: {name: .cluster.name, namespace: .cluster.namespace},
    postgres: (role_rights + {have_password: [], can_log_in: (expected_roles | sort), roles: (expected_roles | sort),
                              databases: (expected_databases | sort)}),
    certificate_logins: certificate_logins(expected_ident),
    client_ca: {secret: .caSecret, certificates: $certificates[0]},
    tls: {"*": {postgresql: tls_minimum, metrics: tls_minimum}},
    kubernetes: {
      superuser_in_cluster_namespace: ($allowed + secret_readers | allowed),
      create_certificates: (certificate_subjects | allowed),
      write_routes: ($allowed | allowed),
      run_pods: ($allowed | allowed),
      become_cluster_admin: ($allowed | allowed),
      operator_reads_secrets_in: (secret_namespaces | allowed),
      plugin_reads_secrets_in: (secret_namespaces | allowed),
      not_served: (["ingressroutes.traefik.io", "ingressroutetcps.traefik.io"] | allowed)
    },
    pods_sharing_host_uids: [],
    details: {
      pg_hba: (expected_pg_hba | numbered),
      pg_ident: (expected_pg_ident | numbered)
    }
  }
