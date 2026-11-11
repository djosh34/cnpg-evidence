# prove.sh

`scripts/prove/prove.sh` tries the logins and host-uid accesses that [rules](../README.md#rules) 1, 2 and 5 forbid, and expects each to fail with its specific denial. One control login must succeed, so a failure shows a denial and not a broken path. Each run leaves failed logins in PostgreSQL's log, so run it by hand, not on a schedule.

## Run

As root on a node that runs an instance, with a cluster-admin kubeconfig, `kubectl`, `jq`, `psql`, `setpriv`, `pgrep` and `python3`:

```bash
yq -o=json samples/desired.yaml | bash scripts/prove/prove.sh > prove.json
yq -o=json samples/desired.yaml | bash scripts/prove/prove.sh --node node-a --node-root '' \
  --postgres-uid 999 --postgres-gid 999 > prove.json
```

- stdin: `samples/desired.yaml` as JSON; it reads the cluster's name and namespace and `rwLoadBalancer.name`.
- `--node`: this node's Kubernetes name. Default the hostname.
- `--node-root`: a prefix for the kubelet and storage paths, for a node seen from elsewhere, such as `/proc/<pid>/root` of a node container. Default none.
- `--postgres-uid`, `--postgres-gid`: the chart's ids. Default 999.

It runs nothing in the pods. The logins use the node's `psql` through every address of the rw LoadBalancer, with no `PG*` variable and an empty `HOME`, so no client certificate of the caller is sent. The replication key stays in memory.

Exit 0: every attempt matched. 1: one differed. 2: a usage or collection error, with nothing on stdout.

## Probes

| Probe | Must |
|---|---|
| `password-tls`, `password-no-tls` | A password login as `postgres` gets the pg_hba reject |
| `tls-no-client-cert` | An application login is asked for a client certificate |
| `replication-cert-as-<role>` | The replication certificate cannot log in as the application role |
| `control-replication-cert` | The replication certificate logs in as `streaming_replica`. Must succeed. |
| `uid-<uid> socket-proc-root` | The host uid cannot log in through the socket under the postgres process's root |
| `uid-<uid> pgdata-host-path` | The host uid cannot read `PG_VERSION` in the data directory on the host |
| `uid-mapped socket-host-path` | The pod's mapped host uid cannot log in through the socket on the host path |
| `uid-probes` | Appears only to fail, as `not found`, when no instance runs on the node |

The uid attempts find each pod's postgres process by its cgroup path, read its uid map, and switch to the uid with no groups or capabilities. A target that does not exist fails as `error`, since it shows no denial.

## Output

```json
{"kind":"actual","source":"prove","collected_at":"2026-01-02T03:04:05Z",
 "node":"node-a","namespace":"databases","cluster":"pg","probes":[
  {"probe":"password-tls","expected":"refused by pg_hba reject","value":"denied","ok":true,
   "raw":[{"target":"10.0.0.1:5432","value":"denied","actual":"FATAL: pg_hba.conf rejects connection"}]}
]}
```

One row per probe. `value` is `denied`, `allowed` or `error`, or each value once when the attempts differ. `raw` holds every attempt with its target and what happened.

`login/login.sh` and `uid/uid.sh` under `scripts/prove/` also run alone and print one record per attempt.
