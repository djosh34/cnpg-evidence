# host-check.sh

`scripts/host-check/host-check.sh` shows the host side of [rule 6](../README.md#rules) on one node: no host user can reach the PostgreSQL socket, data or ServiceAccount token. It also checks that only root can bind ports below 1024 on the node. It only reads.

## Run

On every node, as root:

```bash
bash scripts/host-check/host-check.sh
bash scripts/host-check/host-check.sh --postgres-uid 26 --postgres-gid 26 --storage-dir /var/lib/rancher/k3s/storage
```

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
7. **Assemble the result.** A failed check becomes `ok: false` and does not stop the later checks. A failed collection command stops the run with exit 2.

## Output

Logs go to stderr. Example of stdout, shortened:

```json
{"collected":{"hostname":"node-a","selinux":"enforcing"},"checks":[{"id":"selinux-enforcing","ok":true,"detail":"SELinux is enforcing"}]}
```

Exit 0: every check passed. Exit 1: a check failed. Exit 2: an argument, privilege or collection error, with nothing on stdout. A failed `getent passwd` or `getent group` listing is exit 2; a lookup that finds no such name or id is not an error.

| Key | Meaning |
| --- | --- |
| `collected` | Host facts, without pass or fail. |
| `checks` | One result per check, each with `id`, `ok` and `detail`. |
| `id` | Check name. |
| `ok` | `true` when the check passed. |
| `detail` | What the script found, and why it passed or failed. |

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

| Check | Passes when |
| --- | --- |
| `selinux-enforcing` | The kernel's SELinux mode is enforcing. |
| `postgres-uid-account` | Every account with the PostgreSQL uid or primary gid is locked and has a `nologin` shell. No such account also passes. |
| `postgres-gid-group` | Every member of the PostgreSQL group is locked and has a `nologin` shell. An absent or empty group passes. |
| `postgres-sudoers` | No sudoers line outside comments names `postgres`, a matching account or group, or the uid or gid. In sudoers, `#` followed by a number names a uid and is not a comment. |
| `postgresql-server-absent` | `rpm -qa 'postgresql*-server'` finds no package. |
| `storage-dir-mode` | The storage directory is 0700 or tighter, owned by `root:root`, without an ACL. |
| `kubelet-pods-mode` | `/var/lib/kubelet/pods` is 0750 or tighter, owned by `root:root`, without an ACL. |
| `k3s-kubeconfig-mode` | `/etc/rancher/k3s/k3s.yaml` is 0600 or tighter, owned by `root:root`, without an ACL. |
| `k3s-selinux` | The generated containerd config has `enable_selinux = true`. `detail` shows the k3s SELinux flags. |
| `k3s-network-policy` | No `disable-network-policy` setting appears, not even with value `false`. |
| `subordinate-ids` | No entry is malformed, and no entry other than kubelet's overlaps kubelet's range. That range is 65536–4294967295 unless a `kubelet` account, `getsubids` and a file entry give another. |
| `unprivileged-port-start` | `ip_unprivileged_port_start` is 1024 or higher. |
| `bind-service-capability` | No file under `/usr` or `/opt` carries `cap_net_bind_service`. |

The sudoers check also runs on its own: `bash scripts/host-check/postgres-sudoers/postgres-sudoers.sh UID GID [FILE...]`. Without files it reads `/etc/sudoers` and `/etc/sudoers.d/*`. It searches for the names and numbers; it does not evaluate the sudo policy.

## Limits

- `getent` may not list every account a directory service serves; the direct uid and gid lookups add to it but cannot make it complete.
- k3s flags from environment files and subordinate-id ranges from a directory service are not read.
- The capability search covers files under `/usr` and `/opt` only, not other paths, running processes or service settings.
- Listeners are facts, not checks. File modes do not prove that a login fails; `prove.sh` tries the access.
- Locked accounts, modes and SELinux settings do not show which identities processes that already run use.
