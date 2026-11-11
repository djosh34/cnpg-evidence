# host-check.sh

`scripts/host-check/host-check.sh` checks one node for the host side of [rule 5](../README.md#rules) and for rule 8. It only reads. The `host-check` scenario runs it on every node.

## Run

On every node, as root:

```bash
bash scripts/host-check/host-check.sh > host-check.json
bash scripts/host-check/host-check.sh --node node-a --postgres-uid 999 --postgres-gid 999 \
  --storage-dir /var/lib/rancher/k3s/storage > host-check.json
```

- `--node`: the Kubernetes node name. Default the hostname.
- `--postgres-uid`, `--postgres-gid`: the chart's `cluster.postgresUID` and `postgresGID`. Default 999.
- `--storage-dir`: the parent of the data volumes' host directories. Default k3s local-path's.
- Needs bash, coreutils, sed, awk and jq, and `scripts/host-check/` with `scripts/lib/`. `ss`, `rpm`, `getent`, `k3s` and `iptables-save` are optional and listed in `missing_tools` when absent; a check that needs a missing one fails with `<tool> not found`. Without `iptables-save` it uses the one k3s brings.

Exit 0: every check passed. 1: a check failed. 2: an argument, privilege or collection error, with nothing on stdout.

## Output

```json
{"kind":"actual","source":"host-check","collected_at":"2026-01-02T03:04:05Z","node":"node-a",
 "collected":{"hostname":"node-a","selinux":"enforcing"},
 "checks":[{"id":"selinux","ok":true,"value":"enforcing, enable_selinux true","raw":"/sys/fs/selinux/enforce = 1; ..."},
           {"id":"low-ports","ok":true,"value":"none","raw":"ip_unprivileged_port_start = 1024"}]}
```

- `collected`: facts, not checks: `hostname`, `os`, `kernel`, `k3s_version`, `containerd_version`, `selinux`, `containerd_enable_selinux`, `postgres_uid`, `postgres_gid`, `listening_tcp` and `missing_tools`.
- `checks`: one row per check below, in that order. `value` is the result in the rule's terms, the same on every node when it passes; `raw` is what the check read.

## Checks

| Check | Passes when | `value` when it passes |
|---|---|---|
| `selinux` | The kernel enforces SELinux and k3s's containerd config has `enable_selinux = true` | `enforcing, enable_selinux true` |
| `postgres-account` | Every account with the PostgreSQL uid or primary gid is locked with a `nologin` shell | `none` |
| `dir-modes` | The storage directory is 0700 or tighter and `/var/lib/kubelet/pods` 0750 or tighter, both `root:root`, no ACL | `none` |
| `k3s-secrets` | The kubeconfig and token-bearing config files are 0600, the server directory 0700, all `root:root` without ACL; on a server, `k3s secrets-encrypt status` says `Enabled` | `none` |
| `low-ports` | `ip_unprivileged_port_start` is at least 1024 | `none` |
| `k3s-network-policy` | `INPUT`, `FORWARD` and `OUTPUT` jump to k3s's `KUBE-ROUTER-*` chains | `none` |

A failing value lists what is wrong, items joined with `; `. Group members, sudoers lines and installed `postgresql*-server` packages are listed in `raw` only. `bash scripts/host-check/postgres-sudoers/postgres-sudoers.sh UID GID [FILE...]` runs the sudoers search alone.

A node that runs in a container, as in the scenarios, fails some checks; [`host-check.feature`](../samples/features/host-check.feature) lists them with the reason for each.

## Limits

- `getent` may not list every account of a directory service.
- The network policy check reads IPv4 rules with the host's `iptables-save`. A k3s with `prefer-bundled-bin` that writes the other backend fails it although the controller runs.
- No check finds programs with `cap_net_bind_service`.
- Modes and accounts do not prove that an access fails; `prove.sh` tries it.
