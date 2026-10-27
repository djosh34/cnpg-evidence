# host-check.sh

`scripts/host-check/host-check.sh` shows the host side of [rule 6](../README.md#rules) on one node: no host user can reach the PostgreSQL socket, data or ServiceAccount token. It also checks that only root can bind ports below 1024 on the node. It only reads.

## Run

On every node, as root:

```bash
bash scripts/host-check/host-check.sh
bash scripts/host-check/host-check.sh --node node-a --postgres-uid 26 --postgres-gid 26 \
  --storage-dir /var/lib/rancher/k3s/storage
```

- `--node`: this node's Kubernetes node name, as in `kubectl get nodes`. Default the hostname, which k3s uses unless its `node-name` setting gives another.
- `--postgres-uid`, `--postgres-gid`: PostgreSQL's uid and gid in the CNPG image. Default 26.
- `--storage-dir`: the parent of the host directories that back the PostgreSQL data volumes. Default `/var/lib/rancher/k3s/storage`, where the k3s local-path provisioner creates them. For any PersistentVolume, `spec.local.path` or `spec.hostPath.path` gives its directory on the node.
- Needs bash, coreutils, sed, awk and jq, and the `scripts/host-check/` and `scripts/lib/` directories. `ss`, `rpm`, `getent`, `firewall-cmd`, `k3s` and `getcap` are optional: a missing one is listed in `missing_tools`, and the checks that need it fail. `getsubids` is optional too.

## What happens

1. **Check the input and collect host facts.** The uid and gid must be numbers, the script must run as root, and jq must exist. It records the hostname, OS, kernel, k3s and containerd versions, TCP listeners and the other `collected` keys as facts, not checks. Pods have their own addresses on the cluster's overlay network, so the listener list describes the node, not the pods.
2. **Check accounts and sudoers.** A host process with PostgreSQL's uid or gid can open files that PostgreSQL owns. The script finds the accounts with that uid or primary gid, and the members of the group with that gid. It lists the host account database (NSS) and also looks up the uid and gid directly. Each matching account must have a locked password and a `nologin` shell, and no sudoers line may name it.
3. **Check the installation and directory modes.** A host PostgreSQL server package is reported on its own, because removing it can leave its account behind. Pod volumes are directories on the node, under the storage directory and `/var/lib/kubelet/pods`; kubelet is the node agent that runs pods. The socket and data files in them stay owned by uid 26 on disk, also with a user namespace, so a root-only parent directory is what keeps a host user with uid 26 out. The script checks that both directories are owned by root, have a restrictive mode and carry no ACL. It checks the k3s kubeconfig the same way, since it holds cluster-admin credentials.
4. **Check SELinux and the network policy controller.** k3s bundles Kubernetes and containerd, the runtime that starts containers. With `enable_selinux`, containerd gives each container its own SELinux label, so a host process or another container cannot open its files even with a matching uid. The script reads the kernel's SELinux mode and containerd's generated `enable_selinux` setting, and shows the k3s SELinux flags next to it; the flags alone do not show the setting in effect. It reports any `disable-network-policy` setting, even `false`, because a later file or flag can override it. Its absence does not show that a suitable NetworkPolicy exists; `evidence.sh` reads those.
5. **Check subordinate ids.** User namespaces map container uids and gids to ranges of host ids. kubelet gives each `hostUsers: false` pod a block of host uids from its range. `/etc/subuid` and `/etc/subgid` give accounts ranges of their own. An account whose range overlaps kubelet's shares host uids with pods. The script checks both files against kubelet's range: the range of the `kubelet` entry when that account and `getsubids` exist, otherwise kubelet's default. A malformed entry fails rather than being skipped.
6. **Check low ports.** Ports below 1024 can be bound only by root, unless the kernel threshold `ip_unprivileged_port_start` is lowered or a program file carries `cap_net_bind_service`. The script checks that the threshold is at least 1024 and searches `/usr` and `/opt` for files with that capability. Who can open ports through Kubernetes is in `evidence.sh`.
7. **Assemble the result.** Each check gives a `value` in the terms of its rule, so a check that passes has the same value on every node, and `raw`, what it read. A failed check becomes `ok: false` and does not stop the later checks. A failed collection command stops the run with exit 2.

## Output

Logs go to stderr. Example of stdout, shortened:

```json
{"kind":"actual","source":"host-check","collected_at":"2026-01-02T03:04:05Z","node":"node-a",
 "collected":{"hostname":"node-a","selinux":"enforcing"},
 "checks":[{"id":"selinux-enforcing","ok":true,"value":"enforcing","raw":"/sys/fs/selinux/enforce = 1"},
           {"id":"unprivileged-port-start","ok":true,"value":"1024 or higher","raw":"ip_unprivileged_port_start = 1024"}]}
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
| `k3s_config` | Only the `selinux` and `disable-network-policy` settings from the k3s config files and the `ExecStart` of the `k3s` or `k3s-agent` unit; other settings can hold secrets. |
| `listening_tcp` | Listeners with `address`, `port` and `processes` (`name`, `pid`), or `null` without `ss`. |
| `firewalld` | `state` and active `zones`, each with `zone`, `target`, `interfaces`, `sources`, `services`, `ports` and `rich_rules`, or `null` without `firewall-cmd`. No check reads it. |
| `subuid` | Lines of `/etc/subuid` without comments, or `null`. |
| `subgid` | Lines of `/etc/subgid` without comments, or `null`. |
| `getsubids` | Path of `getsubids`, or `null`. |
| `missing_tools` | Optional tools that are absent. |

### Checks

| Check | Passes when | `value` when it passes | `value` when it fails |
| --- | --- | --- | --- |
| `selinux-enforcing` | The kernel's SELinux mode is enforcing. | `enforcing` | `permissive` or `disabled` |
| `postgres-uid-account` | Every account with the PostgreSQL uid or primary gid is locked and has a `nologin` shell. No such account also passes. | `none` | `not locked with nologin: ` and the accounts that are not |
| `postgres-gid-group` | Every member of the PostgreSQL group is locked and has a `nologin` shell. An absent or empty group passes. | `none` | `not locked with nologin: ` and the members that are not |
| `postgres-sudoers` | No sudoers line outside comments names `postgres`, a matching account or group, or the uid or gid. In sudoers, `#` followed by a number names a uid and is not a comment. | `none` | the lines, as `file:line: text` |
| `postgresql-server-absent` | `rpm -qa 'postgresql*-server'` finds no package. | `none` | the packages |
| `storage-dir-mode` | The storage directory is 0700 or tighter, owned by `root:root`, without an ACL. | `700 or tighter, root:root, no ACL` | the same parts with what differs, such as `755, root:root, no ACL`, or `missing` |
| `kubelet-pods-mode` | `/var/lib/kubelet/pods` is 0750 or tighter, owned by `root:root`, without an ACL. | `750 or tighter, root:root, no ACL` | as above |
| `k3s-kubeconfig-mode` | `/etc/rancher/k3s/k3s.yaml` is 0600 or tighter, owned by `root:root`, without an ACL. | `600 or tighter, root:root, no ACL` | as above |
| `k3s-selinux` | The generated containerd config has `enable_selinux = true`. `raw` shows the k3s SELinux flags. | `true` | the setting, or `unset` |
| `k3s-network-policy` | No `disable-network-policy` setting appears, not even with value `false`. | `none` | the settings |
| `subordinate-ids` | No entry is malformed, and no entry other than kubelet's overlaps kubelet's range. That range is 65536–4294967295 unless a `kubelet` account, `getsubids` and a file entry give another. | `none` | the entries, as `file: line` |
| `unprivileged-port-start` | `ip_unprivileged_port_start` is 1024 or higher. | `1024 or higher` | the threshold |
| `bind-service-capability` | No file under `/usr` or `/opt` carries `cap_net_bind_service`. | `none` | the files with their capabilities |

A missing tool fails its check with the value `<tool> not found`. Values that list several items join them with `; `.

The sudoers check also runs on its own: `bash scripts/host-check/postgres-sudoers/postgres-sudoers.sh UID GID [FILE...]`. Without files it reads `/etc/sudoers` and `/etc/sudoers.d/*`. It searches for the names and numbers; it does not evaluate the sudo policy.

## Limits

- `getent` may not list every account a directory service serves; the direct uid and gid lookups add to it but cannot make it complete.
- k3s flags from environment files and subordinate-id ranges from a directory service are not read.
- The capability search covers files under `/usr` and `/opt` only, not other paths, running processes or service settings.
- Listeners are facts, not checks. File modes do not prove that a login fails; `prove.sh` tries the access.
- Locked accounts, modes and SELinux settings do not show which identities processes that already run use.
