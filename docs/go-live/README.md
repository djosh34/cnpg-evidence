# Go live with an existing CNPG setup

What a running k3s and CNPG setup needs before a new production cluster takes traffic, in order of importance. Each link leads to the details: the problem, how behaviour changes, and what to change or check. Some items are checks of settings that are already right by default: they are listed because nothing else notices when a chart or a person changes them.

It assumes:
- three k3s servers, local-path volumes, CNPG 1.30.1 with the barman-cloud plugin, certificates from an ACME CA through cert-manager;
- a new cluster that imports the old one's databases;
- clients outside the cluster on the rw LoadBalancer only, and no read port;
- synchronous replication with `method: any`, `number: 1`, `dataDurability: required`, `synchronous_commit: remote_apply` and `failoverQuorum: true`, as in the [samples](../samples.md#writes-reads-and-failover). The promises about commits below rest on these;
- clients that list every node, set a short `connect_timeout`, and treat a COMMIT that got no answer as unknown: it may have been committed.

Everything here was measured in the [scenarios](../e2e.md) or read from the upstream source, unless it says otherwise. The variant [`first-list`](../../variants/first-list) of the scenarios applies the base and the list below, and leaves everything else at its default.

## The base

What the list assumes the cluster already has: only checks, no changes. [base.md](base.md)

- Three k3s servers, CNPG 1.30.1 with the barman-cloud plugin. [base.md](base.md#three-k3s-servers-and-cnpg-with-the-barman-cloud-plugin)
- Synchronous replication: `method: any`, `number: 1`, `dataDurability: required`, `synchronous_commit: remote_apply`, `failoverQuorum: true`. [base.md](base.md#synchronous-replication)
- Certificates from an ACME CA through cert-manager. [base.md](base.md#certificates-from-an-acme-ca-through-cert-manager)
- The rw LoadBalancer, and no read port. [base.md](base.md#the-rw-loadbalancer-and-no-read-port)
- WAL archiving and backups to a bucket through the plugin. [base.md](base.md#wal-archiving-and-backups-to-a-bucket)
- Metrics and alerts on the cluster. [base.md](base.md#metrics-and-alerts-on-the-cluster)

## Set when the cluster is created

These cannot change on a running cluster.

- **The import from the old cluster.** A `monolith` import with nothing else under `initdb`, no writes to the old cluster during it, and room for the dump. Otherwise writes go missing, an extra `app` database and Secret appear, or the disk fills. [new-cluster.md](new-cluster.md#the-import-from-the-old-cluster)
- **1 MB WAL files.** A cluster with a few writes every few minutes makes about 288 MiB of WAL files a day instead of 4.5 GiB, before compression. [new-cluster.md](new-cluster.md#1-mb-wal-files)
- **The postgres uid and gid of the image, and a shell in it.** With the wrong uid, local logins and pg_ident break; without `/bin/sh`, CNPG cannot run the image. [new-cluster.md](new-cluster.md#the-postgres-uid-and-gid-of-the-image)

## Failover happens by itself

- **Check: no streaming startup or readiness probe.** With it, a replica that restarts while the primary's node is down never becomes ready, and nothing is promoted. [failover.md](failover.md#no-streaming-probe)
- **The barman-cloud plugin and the CNPG operator on every node.** CNPG does nothing for a cluster, failover included, while its plugin or its operator pod is on a lost node: 5 to 20 minutes. [failover.md](failover.md#the-plugin-and-the-operator-on-every-node)
- **CoreDNS on every node.** A promotion looks up the bucket by name; with the only CoreDNS pod on the lost node, it waits until that node returns. [failover.md](failover.md#coredns-on-every-node)
- **Check: one instance per node.** Two instances on one node can take the primary and its only synchronous copy down together. [failover.md](failover.md#one-instance-per-node)

## Switchovers and rollouts stay short

- **`smartShutdownTimeout: 0`.** A connection pool never closes its sessions, so a stopping primary holds writes for 3 minutes; with 0, about 11 seconds. [switchover.md](switchover.md#smartshutdowntimeout-0)
- **Check: `primaryUpdateMethod` is `restart`.** It is CNPG's default. With `switchover`, CNPG 1.30.1 can hang after a rollout with no primary until a person steps in. [switchover.md](switchover.md#primaryupdatemethod-restart)

## Disk and bucket

- **Check: the data disk is its own filesystem, with room.** A full data disk stops PostgreSQL and CNPG does not fail over; a full node disk gets the instances evicted. [disk-and-bucket.md](disk-and-bucket.md#the-data-disk)
- **Short bucket timeouts and `switchoverDelay: 30`.** A bucket that hangs stalls a failover for about 40 minutes with barman-cloud's defaults; with 5 s and one attempt, about 9. [disk-and-bucket.md](disk-and-bucket.md#short-bucket-timeouts)
- **A bucket nothing can delete from.** A replica that needs a WAL file that is gone never rejoins, and the next failover then cannot happen. [disk-and-bucket.md](disk-and-bucket.md#a-bucket-nothing-can-delete-from)

## Certificates

- **One Issuer per Certificate.** Each Certificate has its own namespaced Issuer and ACME account; no shared ClusterIssuer. [certificates.md](certificates.md#one-issuer-per-certificate)
- **No port 443 on Traefik.** k3s's Traefik serves a self-signed certificate on 443 of every node; http-01 needs only port 80. [certificates.md](certificates.md#no-port-443-on-traefik)
- **The self-signed certificates that stay.** Listed with the reason. Only the k3s ones are on the nodes' ports, and a firewall keeps those out of a scan. [certificates.md](certificates.md#the-self-signed-certificates-that-stay)

## Hardening that is a toggle or a check

- **Check: superuser access off, Secrets encrypted, SELinux in containerd.** Settings that should already be on. [hardening.md](hardening.md#checks)
- **`hostUsers: false`, and a check that it is set.** A process that escapes the container is nobody on the host, not the owner of the data. [hardening.md](hardening.md#hostusers-false)
- **Certificate-only logins, with a manual check.** CNPG's last pg_hba line accepts a password from anywhere. [hardening.md](hardening.md#certificate-only-logins)
- **A NetworkPolicy for the instances.** Only the clients, the operator, the other instances and the collectors reach PostgreSQL. [hardening.md](hardening.md#a-networkpolicy-for-the-instances)

## Metrics and alerts

- **Certificate expiry and disk usage as metrics.** k3s (for its own and etcd's certificates) and cert-manager already export their certificate expiry, and the kubelet the volume usage; the collectors only need to scrape them. [metrics-and-alerts.md](metrics-and-alerts.md)
- **The alerts on them.** [metrics-and-alerts.md](metrics-and-alerts.md#alerts)

## To weigh

- **Replication slots on or off.** On, a replica that stays away can fill the primary's disk; off, a replica that fell far behind needs the bucket to catch up. [trade-offs.md](trade-offs.md#replication-slots)

## Later

What the samples do that can wait. [later.md](later.md)
