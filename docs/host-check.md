# host-check.sh

`scripts/host-check/host-check.sh` shows the host side of [rule 5](../README.md#rules) and rule 8 on one node: SELinux, the accounts with PostgreSQL's ids and the directory modes for rule 5; the k3s credentials, secrets encryption, low ports and the network policy controller for rule 8. It only reads.

## Run

On every node, as root:

```bash
bash scripts/host-check/host-check.sh
bash scripts/host-check/host-check.sh --node node-a --postgres-uid 999 --postgres-gid 999 \
  --storage-dir /var/lib/rancher/k3s/storage
```

- `--node`: this node's Kubernetes node name, as in `kubectl get nodes`. Default the hostname, which k3s uses unless its `node-name` setting gives another.
- `--postgres-uid`, `--postgres-gid`: PostgreSQL's uid and gid, the chart's `cluster.postgresUID` and `cluster.postgresGID`: the ids the image names `postgres`. Default 999, as in the Hummingbird image.
- `--storage-dir`: the parent of the host directories that back the PostgreSQL data volumes. Default `/var/lib/rancher/k3s/storage`, where the k3s local-path provisioner creates them. For any PersistentVolume, `spec.local.path` or `spec.hostPath.path` gives its directory on the node.
- Needs bash, coreutils, sed, awk and jq, and the `scripts/host-check/` and `scripts/lib/` directories. `ss`, `rpm`, `getent`, `k3s` and `iptables-save` are optional: a missing one is listed in `missing_tools`. A missing `getent`, a missing `k3s` on a server node and a missing `iptables-save` fail the check that needs it; a missing `rpm` is only listed in `raw`. Without `iptables-save` on the `PATH`, the network policy check uses the one k3s brings, `/var/lib/rancher/k3s/data/current/bin/aux/iptables-save`, as k3s does on a host without iptables.

## What happens

1. **Check the input and collect host facts.** The uid and gid must be numbers, the script must run as root, and jq must exist. It records the hostname, OS, kernel, k3s and containerd versions, TCP listeners and the other `collected` keys as facts, not checks. Pods have their own addresses on the cluster's overlay network, so the listener list describes the node, not the pods.
2. **Check SELinux.** k3s bundles Kubernetes and containerd, the runtime that starts containers. The script reads the kernel's SELinux mode and containerd's generated `enable_selinux` setting, and shows the k3s SELinux flags next to it; the flags alone do not show the setting in effect.
3. **Check accounts.** A host process with PostgreSQL's uid or gid can open files that PostgreSQL owns. The script lists the host account database (NSS) and also looks up the uid directly. Every account with that uid or primary gid must have a locked password and a `nologin` shell. Group members, matching sudoers lines and installed `postgresql*-server` packages are listed in `raw` only; they do not fail the check.
4. **Check directory modes.** Pod volumes are directories on the node, under the storage directory and `/var/lib/kubelet/pods`; kubelet is the node agent that runs pods. The script checks their modes, root ownership and ACL markers.
5. **Check k3s secrets.** The kubeconfig holds cluster-admin credentials. Config files with `token:` or `agent-token:` settings and the server directory also hold credentials. The script checks their modes, ownership and ACL markers, without printing tokens. On a server it asks the running k3s with `k3s secrets-encrypt status` and needs `Encryption Status: Enabled`, so the setting counts wherever it was made: a config file, the unit, an environment file or the command line. Absent paths pass. When both the kubeconfig and server directory are absent, it reports an agent node and does not require the server directory or secrets encryption. A `k3s secrets-encrypt status` that fails, such as on a server that does not run, is a collection error.
6. **Check low ports and the network policy controller.** The script checks that `ip_unprivileged_port_start` is at least 1024. It then reads the iptables filter table with `iptables-save -t filter` and needs a jump from `INPUT`, `FORWARD` and `OUTPUT` to the chains `KUBE-ROUTER-INPUT`, `KUBE-ROUTER-FORWARD` and `KUBE-ROUTER-OUTPUT` of k3s's network policy controller. k3s starts no controller for its `disable-network-policy` setting, and also by itself, with only a log line, when `ipset` is missing; the chains show the controller in either case. They show that k3s enforces NetworkPolicies, not that a suitable one exists.
7. **Assemble the result.** Each check gives a `value` in the terms of its rule, so a check that passes has the same value on every node, and `raw`, what it read. A failed check becomes `ok: false` and does not stop the later checks. A failed collection command stops the run with exit 2.

## Output

Logs go to stderr. Example of stdout, shortened:

```json
{"kind":"actual","source":"host-check","collected_at":"2026-01-02T03:04:05Z","node":"node-a",
 "collected":{"hostname":"node-a","selinux":"enforcing"},
 "checks":[{"id":"selinux","ok":true,"value":"enforcing, enable_selinux true","raw":"/sys/fs/selinux/enforce = 1; enable_selinux = true in the k3s containerd config; config: selinux: true"},
           {"id":"low-ports","ok":true,"value":"none","raw":"ip_unprivileged_port_start = 1024"}]}
```

Exit 0: every check passed. Exit 1: a check failed. Exit 2: an argument, privilege or collection error, with nothing on stdout. A failed `getent passwd` or `getent group` listing is exit 2; a lookup that finds no such name or id is not an error.

| Key | Meaning |
| --- | --- |
| `kind` | `actual`, a document read from a live node. |
| `source` | `host-check`. |
| `collected_at` | When the script started reading, in UTC, ISO 8601, from the local clock. |
| `node` | `--node`, or the hostname. |
| `collected` | Host facts, without pass or fail. |
| `checks` | One row per check, in the order of the table below, each with `id`, `ok`, `value` and `raw`. |
| `id` | Check name. |
| `ok` | `true` when the check passed. |
| `value` | The result in the terms of the check's rule. A passing check has the value in the table below on every node; any other value fails. |
| `raw` | What the check read: names, modes, lines or settings, on one line. |

### Collected keys

| Key | Meaning |
| --- | --- |
| `hostname` | Kernel hostname. |
| `os` | OS pretty name. |
| `kernel` | Running kernel release. |
| `k3s_version` | First line of the k3s version, or `null`. |
| `containerd_version` | First line of the containerd version, from the k3s binary when it exists, or `null`. |
| `selinux` | `enforcing`, `permissive` or `disabled`, from the kernel. |
| `containerd_enable_selinux` | First `enable_selinux` value in the containerd config k3s generates, or `null`. |
| `postgres_uid` | The uid given. |
| `postgres_gid` | The gid given. |
| `listening_tcp` | Listeners with `address`, `port` and `processes` (`name`, `pid`), or `null` without `ss`. |
| `missing_tools` | Optional tools that are absent. |

### Checks

| Check | Passes when | `value` when it passes | `value` when it fails |
| --- | --- | --- | --- |
| `selinux` | The kernel's SELinux mode is enforcing and the generated containerd config has `enable_selinux = true`. `raw` also shows the k3s SELinux flags. | `enforcing, enable_selinux true` | the mode and setting, such as `permissive; enable_selinux unset` |
| `postgres-account` | Every account with the PostgreSQL uid or primary gid is locked and has a `nologin` shell. No such account also passes. | `none` | `not locked with nologin: ` and the accounts that are not |
| `dir-modes` | The storage directory is 0700 or tighter and `/var/lib/kubelet/pods` is 0750 or tighter, both owned by `root:root`, without an ACL. | `none` | each failing path with its mode, owner and ACL marker, or `missing` |
| `k3s-secrets` | Existing `/etc/rancher/k3s/k3s.yaml` and token-bearing `/etc/rancher/k3s/config.yaml` and `config.yaml.d/*.yaml` are 0600 or tighter; the existing `/var/lib/rancher/k3s/server` is 0700 or tighter; all are `root:root`, without an ACL. On server nodes `k3s secrets-encrypt status` also says `Encryption Status: Enabled`. | `none` | each failing path with what differs, `secrets-encryption off` or `k3s not found` |
| `low-ports` | `ip_unprivileged_port_start` is 1024 or higher. | `none` | the low threshold |
| `k3s-network-policy` | `INPUT`, `FORWARD` and `OUTPUT` jump to `KUBE-ROUTER-INPUT`, `KUBE-ROUTER-FORWARD` and `KUBE-ROUTER-OUTPUT` in the iptables filter table. | `none` | `no jump to: ` and the chains without one, or `iptables-save not found` |

A missing tool needed by a check fails it with the value `<tool> not found`. Values that list several items join them with `; `.

The sudoers search also runs on its own: `bash scripts/host-check/postgres-sudoers/postgres-sudoers.sh UID GID [FILE...]`. Without files it reads `/etc/sudoers` and `/etc/sudoers.d/*`. It searches for the names and numbers; it does not evaluate the sudo policy.

## Limits

- `getent` may not list every account a directory service serves; direct uid and gid lookups add to it but cannot make it complete.
- The SELinux check reads the k3s SELinux flags from `/etc/rancher/k3s/config.yaml`, `config.yaml.d/*.yaml` and the unit's `ExecStart`, not from environment files; they are only shown, the kernel and containerd settings decide.
- The network policy check reads IPv4 rules only.
- No check looks for programs with `cap_net_bind_service`, which can open ports below 1024 whatever the threshold.
- Listeners are facts, not checks. File modes do not prove that a login fails; `prove.sh` tries the access.
- Locked accounts, modes and SELinux settings do not show which identities processes that already run use.

## Known failures on container nodes

A k3s node that runs in a docker container, as in `live/`, fails these checks, each with this value. The `ci` workflow runs `host-check.sh` on such a node with `live/host-check.sh` and fails when any other check fails, or one of these passes or has another value.

| Check | Value | Why |
| --- | --- | --- |
| `selinux` | `disabled; enable_selinux false` | The runner's kernel has no SELinux, and k3s runs without `--selinux` |
| `postgres-account` | `getent not found` | The k3s image has no `getent` |
| `dir-modes` | `/var/lib/rancher/k3s/storage: missing` | No volume was made on the node yet; the local-path provisioner makes the directory with the first one |
| `k3s-secrets` | `secrets-encryption off` | The node runs without `--secrets-encryption` |
| `low-ports` | `ip_unprivileged_port_start = 0` | Docker sets it to 0 in a container's network namespace |
