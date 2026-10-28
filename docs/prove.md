# prove.sh

`scripts/prove/prove.sh` tries each forbidden login, connection and host-uid access, and expects each to fail with the specific denial. Two control attempts must succeed, so that a failure shows a denial and not a broken path. It covers [rules](../README.md#rules) 1 (the replication certificate), 2, 5 and 6.

Every run leaves failed logins in PostgreSQL's log; run it by hand, not on a schedule.

## Run

As root on the node given by `--node`, with a cluster-admin kubeconfig (on a k3s server node, `KUBECONFIG=/etc/rancher/k3s/k3s.yaml`), `kubectl`, `jq`, `psql`, `setpriv`, `pgrep` and `python3`. The desired state comes on stdin as JSON, as for `evidence.sh`:

```bash
yq -o=json desired.yaml | bash scripts/prove/prove.sh
yq -o=json desired.yaml | bash scripts/prove/prove.sh --node node-a --node-root '' --postgres-uid 26
```

From [`desired.yaml`](../desired.yaml) it takes `cluster.namespace` and `cluster.name`, the rw LoadBalancer `rwLoadBalancer.name` and the read LoadBalancer `readLoadBalancer.name`, when that block is set.

- `--node`: this node's Kubernetes node name, as in `kubectl get nodes`. Default the output of `hostname`. The uid attempts read this node's processes, so run the script on that node, and pick a node that runs an instance.
- `--node-root`: a prefix for the kubelet and storage paths, for a node whose filesystem is seen under another path, such as a node in a container seen through `/proc/<pid>/root`. Default none; leave it empty when the script runs on the node itself.
- `--postgres-uid`: PostgreSQL's uid in the CNPG image. Default 26.

## What happens

### 1. Logins from the node

The script reads the CNPG `Cluster`. It takes the application database and role from the first `hostssl ... cert` line in its pg_hba, and the replication certificate and key from the `<cluster>-replication` Secret.

The rw LoadBalancer Service forwards its port on every address in `status.loadBalancer.ingress` to the primary, and the read LoadBalancer its port to the instance on the same node. The script tries every address and port of both. A node whose instance is not ready, or that runs none, refuses the read port, so the login rows fail through that address until the instance is ready.

- Password logins as `postgres` to `postgres`, with and without TLS, must get the pg_hba reject.
- An application login without a client certificate must be asked for one.
- The replication certificate must fail as the application role, and must not let `streaming_replica` into the application database.
- Control: the same certificate must log in as `streaming_replica` to the `postgres` database, which CNPG's fixed pg_hba line allows. This shows that the certificate and the connection path work.

The replication key reaches `psql` as an in-memory file and is never written to disk (`login/key.py`).

### 2. Connections from another namespace

The script collects the address of every instance pod and the addresses and ports of both LoadBalancers. Pods have their own addresses on the cluster's overlay network, separate from the node addresses. The sample chart's LoadBalancers open no NodePort; the ports section of `evidence.sh` shows that none exists.

It creates the namespace `prove-<time>-<pid>` and starts one pod there with the CNPG image of the cluster, which has the client commands it needs. A namespace scopes object names and permissions, but does not separate the network; the NetworkPolicy filters which sources reach which ports. NetworkPolicy never filters connections from the node itself (host processes and hostNetwork pods) to a pod on that node; pods on the same node are filtered as usual.

From that pod:

- Control: a connection to the Kubernetes API on 443 must succeed, which shows that the pod's network works.
- Connections to each instance pod's address on 5432 (PostgreSQL), 8000 (the CNPG instance manager) and 9187 (metrics) must time out or be refused.
- Logins as `postgres` to `postgres` with `sslmode=require` through every LoadBalancer address and port must not get in: a pg_hba reject or no connection passes; a login or any other error fails.

Logins from the node time out after five seconds, connections from the pod after three. Every psql call names the host, port, database and user. No `PG*` environment variable of the caller or of the image reaches psql; the script sets only the timeout and, for the replication certificate, `PGSSLCERT` and `PGSSLKEY`. The script waits up to 180 seconds for the pod to finish, reads its log and deletes the namespace. It also deletes the namespace when a step fails, and logs its name, so a namespace left by an interrupted run can be found.

### 3. Access as the host postgres uid

The script selects the instance pods on `--node`. It finds each pod's postgres process by the pod's object id (`metadata.uid`, not a Unix uid), which appears in the process's cgroup path. `/proc/<pid>/uid_map` gives the host uid that the pod's uid 26 runs as. The script also tries the socket's host path as that mapped uid.

Each pod is tried through two views:

- `/proc/<pid>/root`: the process's own filesystem.
- Host paths: the volumes kubelet mounts for the pod. The pod's PersistentVolumeClaim names a PersistentVolume, whose `spec.local.path` or `spec.hostPath.path` is the data directory on the node.

The targets are the socket, the process environment, the data directory and the ServiceAccount token. A ServiceAccount is the identity a pod runs as in Kubernetes, and its token authenticates API requests.

As root the script first checks that each target exists; a missing path cannot show a denial. It then switches to uid and gid `--postgres-uid`, drops supplementary groups and capabilities, and turns off privilege escalation. As that uid it tries a socket login as `postgres` and reads one byte of each file to `/dev/null`. It repeats the socket login on the host path as the pod's mapped uid. A socket login first changes into the socket directory as the trying uid, so the directory modes apply. Socket logins use PostgreSQL's `local` pg_hba lines, not the TCP certificate lines, so this is a separate path.

### 4. Combine the results

Each of the three groups writes one JSON record per attempt; `prove.sh` combines them when all three have finished. A denial must show the expected failure text and a control must succeed; an unrelated error never counts as a denial. Attempts with the same probe name, such as one login per LoadBalancer address or one connection per instance pod, become one row.

The groups also run on their own and print their records, one per line:

- `bash scripts/prove/login/login.sh NAMESPACE CLUSTER LB_SERVICE...`: logins from the node.
- `bash scripts/prove/pod/pod.sh NAMESPACE CLUSTER LB_SERVICE...`: attempts from the pod in another namespace.
- `bash scripts/prove/uid/uid.sh NAMESPACE CLUSTER NODE NODE_ROOT POSTGRES_UID`: host-uid attempts.

## Output

```json
{"kind":"actual","source":"prove","collected_at":"2026-01-02T03:04:05Z",
 "node":"node-a","namespace":"databases","cluster":"pg","probes":[
  {"probe":"password-tls","expected":"refused by pg_hba reject","value":"denied","ok":true,
   "raw":[{"target":"10.0.0.1:5432","value":"denied","actual":"FATAL: pg_hba.conf rejects connection"}]}
]}
```

Exit 0: every attempt matches. Exit 1: at least one differs. Exit 2: a usage or collection error, with nothing on stdout.

- `kind`: `actual`, a document read from a live cluster.
- `source`: `prove`.
- `collected_at`: when the script started, in UTC, ISO 8601, from the local clock.
- `node`: the node of the host-uid attempts.
- `namespace`: the cluster's namespace.
- `cluster`: the CNPG `Cluster` name.
- `probes`: one row per probe name, the login, pod and uid probes in that order.
- `probe`: the attempt, named without addresses, pods or mapped uids, so the same probe has the same name on every cluster.
- `expected`: the result it needs.
- `value`: `denied` when the attempt failed with the expected denial, `allowed` when it got through, `error` when it failed in another way, or a target was missing. A denial probe passes with `denied`, a control with `allowed`. When the attempts of one row differ, the value lists each once, such as `denied, allowed`.
- `ok`: `true` when every attempt of the row matches.
- `raw`: each attempt, with its `target` (address and port, pod, or pod and mapped uid), its `value` and `actual`: what happened, on one line. Login and uid results are cut to 400 characters. `succeeded:` marks a forbidden attempt that got through.

## Probes

- `password-tls`: a password login with TLS gets the pg_hba reject. One attempt per address and port of each LoadBalancer, as for every login probe below.
- `password-no-tls`: a password login without TLS gets the pg_hba reject.
- `tls-no-client-cert`: an application login is asked for a client certificate.
- `replication-cert-as-ROLE`: the replication certificate cannot log in as the application role.
- `replication-cert-as-streaming_replica`: `streaming_replica` gets the pg_hba reject for the application database.
- `control-replication-cert`: the replication certificate logs in as `streaming_replica` to `postgres`. Must succeed.
- `control-other-namespace`: the pod in another namespace connects to the Kubernetes API on 443. Must succeed.
- `other-namespace-5432`, `other-namespace-8000`, `other-namespace-9187`: each instance pod's address on that port times out or refuses the connection.
- `other-namespace-lb`: through each address and port of both LoadBalancers, a pg_hba reject or no connection (refused, or a `psql` connect timeout); a login or any other error fails.
- `uid-UID socket-proc-root`: the host uid cannot log in through the socket under the process root. One attempt per instance pod on the node.
- `uid-UID token-proc-root`: the host uid cannot read the ServiceAccount token under the process root.
- `uid-UID environ`: the host uid cannot read the postgres process environment.
- `uid-UID socket-host-path`: the host uid cannot reach the socket on the host path and log in.
- `uid-mapped socket-host-path`: the same as the pod's mapped uid.
- `uid-UID token-host-path`: the host uid cannot read the token on the host path.
- `uid-UID pgdata-host-path`: the host uid cannot read `PG_VERSION` in the data directory on the host path.
- `uid-probes`: appears only to fail, with the value `not found`, when no instance runs on the node or a pod's postgres process is not found.

A uid probe whose target is missing as root fails too, with the value `error`, since a missing path shows no denial.
