# Hardening that is a toggle or a check

Only what is one setting or a check. More is in [later.md](later.md).

## Checks

Settings that should already be on.

### Superuser access off

**Problem.** With `enableSuperuserAccess: true`, `postgres` gets a password and CNPG keeps it in the Secret `<cluster>-superuser`. Whoever reads that Secret, or guesses the password, is superuser over the network.

**What changes.** `postgres` has no password and there is no such Secret. Local logins inside the pod and the operator need no password.

**How.** It is CNPG's default; check that nothing turns it on:

```bash
kubectl get cluster -n <namespace> <cluster> -o jsonpath='{.spec.enableSuperuserAccess}'   # empty or false
kubectl get secret -n <namespace> <cluster>-superuser                                      # NotFound
```

### k3s Secrets encryption

**Problem.** Without it, the Secrets, certificate keys and bucket credentials among them, sit in plain text in etcd and in every etcd snapshot.

**What changes.** k3s encrypts Secrets before they reach etcd.

**How.** On every server:

```bash
k3s secrets-encrypt status          # Encryption Status: Enabled
grep secrets-encryption /etc/rancher/k3s/config.yaml   # secrets-encryption: true
```

If it is off on a running cluster (k3s v1.33.10 or later): `k3s secrets-encrypt enable`, restart every server with `secrets-encryption: true`, `k3s secrets-encrypt rotate-keys`, and restart again ([k3s docs](https://docs.k3s.io/cli/secrets-encrypt)). Keep the server token: a snapshot restored with another token cannot be read.

### SELinux in containerd

**Problem.** With SELinux enforcing on the host but off in containerd, containers get no SELinux label of their own, so SELinux does not keep a process that escapes one container away from the files of the others, the database's included.

**What changes.** Every container gets its own SELinux categories, and a container cannot touch another's files.

**How.** On every node:

```bash
getenforce                                                          # Enforcing
grep '^selinux' /etc/rancher/k3s/config.yaml                        # selinux: true
grep enable_selinux /var/lib/rancher/k3s/agent/etc/containerd/config.toml   # enable_selinux = true
rpm -q k3s-selinux
ps -eZ | grep postgres | head -3                                    # container_t:s0:c<n>,c<m>, not spc_t
```

The k3s-selinux policy labels only `/var/lib/rancher/k3s/storage` for volumes; local volumes elsewhere need the label `container_file_t`.

## hostUsers: false

**Problem.** PostgreSQL runs as the image's postgres uid, for example 999, and that is the same uid on the host. Any host user with that uid can read the data directory and connect to the socket as `postgres`.

**What changes.** The pod runs in its own user namespace: uid 999 in the pod is a high, unused uid on the host. A host user with uid 999 is nobody to the pod.

**How.** Needs RHEL 9.4 or later on every node (kernel 5.14.0-427 or later; earlier kernels lack idmapped mounts on tmpfs). On the `Cluster`:

```yaml
metadata:
  annotations:
    cnpg.io/podPatch: '[{"op":"add","path":"/spec/hostUsers","value":false}]'
```

It applies to new pods, so restart the instances once (`kubectl cnpg restart <cluster> -n <namespace>`). It was not run together with k3s's SELinux mode on a real node: apply it to a test cluster on the same nodes first. Check:

```bash
uname -r                                                                       # 5.14.0-427 or later
kubectl get pod -n <namespace> <instance pod> -o jsonpath='{.spec.hostUsers}'  # false
ps -o uid=,comm= -C postgres | head -3                                         # a high uid, not the image's
awk -F: '$2 + $3 > 65536' /etc/subuid /etc/subgid                              # nothing: see below
```

The pods' uids come from the range above 65536. A host user with a subordinate id range there (`useradd` on RHEL hands out ranges from 100000) can map those uids into a namespace of its own and so become the pod's postgres. Keep `/etc/subuid` and `/etc/subgid` free of such ranges.

## Certificate-only logins

**Problem.** CNPG's last pg_hba line accepts a password login from any address for any role. A leaked or guessed password works from anywhere that reaches 5432.

**What changes.** Each database accepts only its own role, only with a client certificate whose CN maps to that role, and every other TCP login is rejected before CNPG's password line. CNPG's own lines for local logins and replication stay first.

**How.** Only with a manual check before and after, because any client that still uses a password stops. In the `Cluster` (as in [`cluster.yaml`](../../samples/charts/cnpg-cluster/templates/cluster.yaml)):

```yaml
spec:
  postgresql:
    pg_hba:
      - hostssl <database> <role> all cert map=clients   # one line per database
      - host all all all reject
    pg_ident:
      - cnpg_streaming_replica <replication certificate CN> streaming_replica
      - clients <client certificate CN> <role>           # one line per client CN
  managed:
    roles:
      - name: <role>
        ensure: present
        login: true
        disablePassword: true
```

Before: list every client, its certificate's CN and its database, and confirm each logs in with its certificate. After:

```bash
psql "host=<node> dbname=<database> user=<role> sslmode=verify-full sslrootcert=ca.crt sslcert=client.crt sslkey=client.key" -c 'select 1'   # works
psql "host=<node> dbname=<database> user=<role> password=x sslmode=require" -c 'select 1'   # rejected: no pg_hba.conf entry / reject
```

Right after an in-place restart of an instance, its pg_ident holds CNPG's own lines only, for a few seconds; certificate logins wait until the cluster's lines are back.

## A NetworkPolicy for the instances

**Problem.** Without one, any pod in the cluster reaches PostgreSQL on 5432, the instance manager on 8000 and the metrics on 9187.

**What changes.** 5432 only from outside the cluster, the nodes and the other instances; 8000 only from the operator and the other instances; 9187 only from the collectors' namespace.

**How.** [`networkpolicy.yaml`](../../samples/charts/cnpg-cluster/templates/networkpolicy.yaml) of the cluster chart, with the rw LoadBalancer only. It must select pods by `cnpg.io/cluster`, not by role, or a new replica's join Job is blocked and never joins. It reads every node's `spec.podCIDR`, so it is rendered with `--dry-run=server` and a new node needs a `helm upgrade`. Connections that are open stay open when the policy narrows.
