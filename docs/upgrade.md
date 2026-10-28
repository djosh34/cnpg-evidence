# Upgrade from v0.1.0

What changes from v0.1.0 to v0.2.0, and what to do before and after the upgrade.

## Before the chart upgrade

- **`rwLoadBalancer.create` is gone.** The chart always puts the rw LoadBalancer in the `Cluster`, and CNPG creates it. Remove the key from your copy of `samples/chart/values.yaml`. A restore next to a running cluster now sets `--set rwLoadBalancer.name=pg-restore-rw-lb --set readLoadBalancer=null` in place of `--set rwLoadBalancer.create=false` (see [samples.md](samples.md#restore-into-a-new-cluster)).
- **A Service made outside the chart must go.** CNPG refuses a Service of the rw or read name that it did not create (`refusing to reconcile service: ..., not owned by the cluster`). Delete such a Service before `helm upgrade`. Its port is closed until CNPG has made the new one.
- **The optional `readLoadBalancer` block.** `desired.yaml` can set `readLoadBalancer: {name, port}`, a read port on every node that leads only to the instance on that node. The example sets `pg-read-lb` on 5433. Leave the block out for no read port. `evidence.sh`, `prove.sh` and `desired.sh` read the same block, so give them the `desired.yaml` the chart used. See [samples.md](samples.md#loadbalancers) for how it behaves and how clients connect to it.

## The chart upgrade

- **No NodePorts.** Both LoadBalancers set `allocateLoadBalancerNodePorts: false`. A NodePort the rw Service had before stays after the upgrade, because Kubernetes keeps a NodePort it has allocated. Remove it once, then check that `kubectl get svc -n databases` shows no second port for the Service:

  ```bash
  kubectl patch service pg-rw-lb -n databases --type=json -p '[{"op":"remove","path":"/spec/ports/0/nodePort"}]'
  ```

  Until then, `evidence.sh` reports the NodePort under rule 9.
- **Commits and readiness.** `synchronous` adds `dataDurability: required`: a commit waits for one other instance and stops while none can confirm it. A replica is ready only while it streams and is less than 16Mi behind (`probes.readiness`). The measured effect of a node loss is in [samples.md](samples.md#clients-on-the-read-port).

## Scripts

- **`prove.sh` reads the desired state on stdin,** as `evidence.sh` does: `yq -o=json desired.yaml | bash scripts/prove/prove.sh`. Without stdin it waits for input. It drops `--namespace`, `--cluster` and `--lb-service`, and exits 2 when given one; the names come from `cluster` and the LoadBalancer blocks of `desired.yaml`. `--node`, `--node-root` and `--postgres-uid` stay.
- **`prove.sh` probes.** The login probes and `other-namespace-lb` try every address and port of both LoadBalancers. The `other-namespace-nodeport` probe is gone; the ports section of `evidence.sh` shows that no NodePort exists.
- **Rule 9.** A new rule for the ways into PostgreSQL besides a login. `evidence.sh` has a new `ports` section: every Service in any namespace that reaches an instance pod, by its selector or its EndpointSlices, and the host ports of the instance pods. The Kubernetes rights add `port_forward` on the instance pods, and `can_open_node_ports` adds Traefik's `ingressroutetcps.traefik.io` where the cluster serves it. See [evidence.md](evidence.md#ports).
- **`psql` runs with no caller environment.** Every psql call of `evidence.sh` and `prove.sh` names its host or socket, port, database and user, and no `PG*` variable of the caller or the image reaches it.

## Images

- **Image list.** The certificate names pair is gone; the accounts image shows the certificate names that log in as each account. A new Services and host ports pair follows the network pair. The evidence images are renumbered, from `evidence-01-accounts` to `evidence-13-versions`. The prove images get a Tried on column. The full list is in [report.md](report.md#output-file-names).
- **Marks.** Every yes or no is a square. A right beyond desired is a red filled square, and a protection that is off a red empty square. An extra row shows only its name in red. Values the actual document lacks are not drawn; a value that means every port reads `all`, never empty. Each image has a legend of its marks, and each actual image says Passed or Failed. See [report.md](report.md#reading-the-images).
- **A container run.** `cnpg-report` can run in its image with one `docker run` command, without copying the binary out (see [report.md](report.md#in-a-container)).
