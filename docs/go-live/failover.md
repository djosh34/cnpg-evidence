# Failover happens by itself

With these, losing the primary's node gives a new primary that takes writes without a person: about 75 seconds later in the scenarios, most of it Kubernetes marking the node as lost (k3s's default 50 s node grace period).

## No streaming probe

**Problem.** With `probes.startup.type: streaming` (or the same for readiness), an instance is ready only once it streams from a primary. When the primary's node is lost and a replica restarts at that moment, that replica can never become ready: there is no primary to stream from. The failover quorum needs every replica ready to decide, so nothing is promoted until the old node returns. Promoting a replica by hand then risks the wrong one: in a test, that lost 75 commits the clients had been told were done. With a streaming readiness probe, no replica was promoted at all.

**What changes.** With CNPG's default probes (`pg_isready`), an instance is ready once PostgreSQL accepts connections. The quorum promotes the replica that holds every confirmed commit, in about 80 to 120 seconds, and keeps every commit. The cost, a replica serving reads while it is still behind, does not exist without a read port.

**How.** Check that the `Cluster` sets no streaming probe:

```bash
kubectl get cluster -n <namespace> <cluster> -o jsonpath='{.spec.probes}'
# empty, or no "type":"streaming" under startup or readiness
```

If it does, remove `spec.probes.startup` and `spec.probes.readiness`.

## The plugin and the operator on every node

**Problem.** Kubernetes moves the pods of a lost node only after 5 minutes. CNPG does nothing for a cluster while one of its plugins does not answer, failover included, and retries with a back-off of up to about 17 minutes. With the only barman-cloud plugin pod on the lost node, a failover took 6.5 minutes in one test, and in another there was still no primary after 15 minutes. With the only operator pod on the lost node, nothing reconciles until the pod has moved (not measured).

**What changes.** One plugin pod and one operator pod per node. The pods elect a leader; when the leader's node is lost, another pod takes over within about 20 seconds. Failover then took 69 to 88 seconds in 16 runs.

**How.** In the values of the `plugin-barman-cloud` chart (as in [`cnpg-plugin-barman-cloud/values.yaml`](../../samples/charts/cnpg-plugin-barman-cloud/values.yaml)):

```yaml
replicaCount: 3
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: plugin-barman-cloud
```

In the values of the `cloudnative-pg` chart (as in [`cnpg-cloudnative-pg/values.yaml`](../../samples/charts/cnpg-cloudnative-pg/values.yaml)):

```yaml
replicaCount: 3
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: cloudnative-pg
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 0        # with a pod on every node, an extra pod has nowhere to go
    maxUnavailable: 1
```

The plugin chart replaces all its pods at once on an update; upgrade it when no failover is expected. Check that each has one pod per node:

```bash
kubectl get pods -n cnpg-system -o wide
```

## CoreDNS on every node

**Problem.** k3s runs one CoreDNS pod. A promotion fetches files from the bucket, which it finds by name. With the only CoreDNS pod on the lost node, the promotion waited for DNS, and writes came back only when the node returned.

**What changes.** A CoreDNS pod on every node; losing one leaves the others answering.

**How.**

```bash
kubectl scale deployment coredns -n kube-system --replicas=3
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide   # one pod per node
```

k3s's CoreDNS manifest sets no replica count, so the scale holds across k3s restarts and upgrades.

## One instance per node

**Problem.** With CNPG's default, preferred anti-affinity, two instances can land on one node. Losing that node can take the primary and its only synchronous copy together; the quorum then refuses to promote the third instance, since it cannot tell whether that one holds every commit. This follows from how the quorum works; it was not measured.

**What changes.** Every instance on its own node, so a commit's two copies never share one.

**How.** Check the `Cluster`:

```yaml
spec:
  affinity:
    podAntiAffinityType: required
```

```bash
kubectl get cluster -n <namespace> <cluster> -o jsonpath='{.spec.affinity.podAntiAffinityType}'   # required
```
