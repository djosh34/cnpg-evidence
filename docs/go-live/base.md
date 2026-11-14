# The base

What the list assumes a cluster already has. Nothing here is a change: each item is a check that the cluster has it. If one fails, set that up first; the list's promises rest on it.

The commands use `-n <namespace>` and `<cluster>` for the CNPG cluster.

## Three k3s servers and CNPG with the barman-cloud plugin

```bash
kubectl get nodes -o wide                                   # three servers, Ready
kubectl get storageclass                                    # local-path
kubectl get deployment -A -l app.kubernetes.io/name=cloudnative-pg -o jsonpath='{.items[*].spec.template.spec.containers[0].image}'      # cloudnative-pg:1.30.1
kubectl get deployment -A -l app.kubernetes.io/name=plugin-barman-cloud                                                                    # one, available
kubectl get cluster -n <namespace> <cluster> -o jsonpath='{.spec.instances}'                                                               # 3
```

## Synchronous replication

Every commit waits until one other instance has applied it, and stops while none can confirm it. Promotion takes only a replica that holds every confirmed commit.

```bash
kubectl get cluster -n <namespace> <cluster> -o jsonpath='{.spec.postgresql.synchronous}'
# "method":"any", "number":1, "dataDurability":"required", "failoverQuorum":true
kubectl cnpg psql -n <namespace> <cluster> -- -tAc 'SHOW synchronous_commit'   # remote_apply
```

## Certificates from an ACME CA through cert-manager

The server and replication certificates come from cert-manager, from the ACME CA, and CNPG makes no CA of its own.

```bash
kubectl get pods -n cert-manager                                                                      # running
kubectl get issuers,clusterissuers -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,ACME:.spec.acme.server   # the ACME CA's directory
kubectl get certificate -A                                                                            # every one Ready
kubectl get cluster -n <namespace> <cluster> -o jsonpath='{.spec.certificates}'
# serverTLSSecret, serverCASecret, clientCASecret and replicationTLSSecret all set
```

## The rw LoadBalancer, and no read port

Clients outside the cluster reach the primary on 5432 of every node, and nothing else.

```bash
kubectl get cluster -n <namespace> <cluster> -o jsonpath='{.spec.managed.services.additional[*].selectorType}'   # rw only
kubectl get svc -n <namespace>                                                                                  # one LoadBalancer, on 5432
```

## WAL archiving and backups to a bucket

```bash
kubectl get cluster -n <namespace> <cluster> -o jsonpath='{.spec.plugins}'
# barman-cloud.cloudnative-pg.io with "isWALArchiver":true and its ObjectStore
kubectl get cluster -n <namespace> <cluster> -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}'   # True
kubectl get scheduledbackup -n <namespace>                                                              # one for the cluster, method plugin
kubectl get backup -n <namespace> --sort-by=.metadata.creationTimestamp                                 # the newest completed
```

## Metrics and alerts on the cluster

The collectors scrape every instance's exporter on 9187, the rule evaluator has the [rules](../monitoring.md), and Alertmanager routes their alerts. The compliance query needs its two grants ([samples.md](../samples.md#compliance-metric)).

```bash
kubectl get cluster -n <namespace> <cluster> -o jsonpath='{.spec.monitoring}'   # the queries' ConfigMap or Secret
```

In the rule evaluator:

```promql
count(cnpg_collector_up{namespace="<namespace>", cluster="<cluster>"} == 1)              # the number of instances
count by (pod) (cnpg_compliance_violations{namespace="<namespace>", cluster="<cluster>"})  # 4 for every instance
```
