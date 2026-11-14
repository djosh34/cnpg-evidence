# Go live with an existing CNPG setup

What a running k3s and CNPG setup needs before a new production cluster takes traffic, in order of importance. It assumes three k3s servers, local-path volumes, CNPG 1.30.1 with the barman-cloud plugin, certificates from an ACME CA through cert-manager, clients outside the cluster on the rw LoadBalancer only, and no read port. Each link leads to the details: the problem, how behaviour changes, and what to change or check.

Everything here was measured in the [scenarios](../e2e.md) or read from the upstream source, unless it says otherwise.

## Set when the cluster is created

These cannot change on a running cluster.

- **1 MB WAL files.** A quiet cluster writes about 288 MiB of WAL a day instead of 4.5 GiB, into `pg_wal` and the bucket. [new-cluster.md](new-cluster.md#1-mb-wal-files)
- **The postgres uid and gid of the image, and a shell in it.** With the wrong uid, local logins and pg_ident break; without `/bin/sh`, CNPG cannot run the image. [new-cluster.md](new-cluster.md#the-postgres-uid-and-gid-of-the-image)

## Failover happens by itself

- **No streaming startup or readiness probe.** With it, a replica that restarts while the primary's node is down never becomes ready, and nothing is promoted. [failover.md](failover.md#no-streaming-probe)
- **The barman-cloud plugin and the CNPG operator on every node.** CNPG does nothing for a cluster, failover included, while its plugin or its operator pod is on a lost node: 5 to 20 minutes. [failover.md](failover.md#the-plugin-and-the-operator-on-every-node)
- **CoreDNS on every node.** A promotion looks up the bucket by name; with the only CoreDNS pod on the lost node, it waits until that node returns. [failover.md](failover.md#coredns-on-every-node)
- **One instance per node.** Two instances on one node can take the primary and its only synchronous copy down together. [failover.md](failover.md#one-instance-per-node)

## Switchovers and rollouts stay short

- **`smartShutdownTimeout: 0`.** A connection pool never closes its sessions, so a stopping primary holds writes for 3 minutes; with 0, about 11 seconds. [switchover.md](switchover.md#smartshutdowntimeout-0)
- **`primaryUpdateMethod: restart`.** In CNPG 1.30.1, a switchover after a rollout can hang with no primary until a person steps in. [switchover.md](switchover.md#primaryupdatemethod-restart)

## Disk and bucket

- **The data disk: its own filesystem, with room.** A full data disk stops PostgreSQL and CNPG does not fail over; a full node disk gets the instances evicted. [disk-and-bucket.md](disk-and-bucket.md#the-data-disk)
- **Short bucket timeouts.** A bucket that hangs stalls a failover for about 40 minutes with barman-cloud's defaults; with 5 s and one attempt, about 9. [disk-and-bucket.md](disk-and-bucket.md#short-bucket-timeouts)
- **A bucket nothing can delete from.** A replica that needs a WAL file that is gone never rejoins, and the next failover then cannot happen. [disk-and-bucket.md](disk-and-bucket.md#a-bucket-nothing-can-delete-from)

## Certificates

- **One Issuer per Certificate.** Each Certificate gets its own ACME account, so orders never wait on another certificate's account. [certificates.md](certificates.md#one-issuer-per-certificate)
- **No port 443 on Traefik.** k3s's Traefik serves a self-signed certificate on 443 of every node; http-01 needs only port 80. [certificates.md](certificates.md#no-port-443-on-traefik)
- **The self-signed certificates that stay.** All of them are inside the cluster and listed with the reason. [certificates.md](certificates.md#the-self-signed-certificates-that-stay)

## Hardening that is a toggle or a check

- **Superuser access off, Secrets encrypted, SELinux in containerd.** Checks of settings that should already be on. [hardening.md](hardening.md#checks)
- **`hostUsers: false`.** The host's postgres uid is nobody inside the pod. [hardening.md](hardening.md#hostusers-false)
- **Certificate-only logins, with a manual check.** CNPG's last pg_hba line accepts a password from anywhere. [hardening.md](hardening.md#certificate-only-logins)
- **A NetworkPolicy for the instances, maybe.** Only the clients, the operator, the other instances and the collectors reach PostgreSQL. [hardening.md](hardening.md#a-networkpolicy-for-the-instances)

## Metrics and alerts

- **Certificate expiry and disk usage as metrics.** k3s, etcd and cert-manager already export their certificate expiry, and the kubelet the volume usage; the collectors only need to scrape them. [metrics-and-alerts.md](metrics-and-alerts.md)
- **The alerts on them.** [metrics-and-alerts.md](metrics-and-alerts.md#alerts)

## To weigh

- **Replication slots on or off.** On, a replica that stays away can fill the primary's disk; off, a replica that fell far behind needs the bucket to catch up. [trade-offs.md](trade-offs.md#replication-slots)

## Later

What the samples do that can wait. [later.md](later.md)
