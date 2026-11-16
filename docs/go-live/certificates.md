# Certificates

## One Issuer per Certificate

**Problem.** One Issuer or ClusterIssuer is shared by several Certificates. cert-manager orders every certificate of an Issuer through that Issuer's one ACME account, so they all share it.

**What changes.** Each Certificate has its own namespaced Issuer, and so its own ACME account. There is no shared ClusterIssuer for them.

**How.** One Issuer per Certificate, in the Certificate's namespace, each with its own account key Secret:

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: pg-server                # one per Certificate, e.g. pg-server and pg-replication
  namespace: databases
spec:
  acme:
    server: https://<acme server>/directory
    privateKeySecretRef:
      name: pg-server-acme-account   # cert-manager creates the account key here
    externalAccountBinding:
      keyID: <key id>
      keySecretRef:
        name: pg-server-acme-eab
        key: secret
    solvers:
      - http01:
          ingress:
            ingressClassName: traefik
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: pg-server
  namespace: databases
spec:
  issuerRef:
    kind: Issuer
    name: pg-server
  # secretName, commonName, dnsNames, usages as before
```

cert-manager uses the external account binding only to register the account. Afterwards the account key in `privateKeySecretRef` is enough. If that account key Secret is lost, cert-manager registers a new account and needs a valid EAB key again. The [cluster chart](../../samples/charts/cnpg-cluster) has one `issuer` value for both of its Certificates; give each its own, as the first-list variant's [`certificates.yaml`](../../variants/first-list/charts/cnpg-cluster/templates/certificates.yaml) does.

Check that every Certificate names its own Issuer:

```bash
kubectl get certificate -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,KIND:.spec.issuerRef.kind,ISSUER:.spec.issuerRef.name
```

## No port 443 on Traefik

**Problem.** k3s's Traefik listens on 443 of every node and, with no certificate configured for it, answers with its own self-signed `TRAEFIK DEFAULT CERT`. A scan of the nodes flags it.

**What changes.** Traefik listens on port 80 only. cert-manager's http-01 challenges need nothing else, and k3s's Traefik does not redirect 80 to 443. Traefik still builds its default certificate in memory; it is served only if someone adds a TLS route (an IngressRoute with `tls`, or an Ingress with `traefik.ingress.kubernetes.io/router.tls`), so who may write routes decides that.

**How.** Add `ports.websecure: null` to the `valuesContent` of the existing HelmChartConfig `traefik`, on every server in `/var/lib/rancher/k3s/server/manifests/`. If there is none, create `traefik-config.yaml` there with this content. A second file with another HelmChartConfig `traefik` replaces the first one's values instead of adding to them. The sample [`traefik-config.yaml`](../../samples/k3s/manifests/traefik-config.yaml) does not have this line; the [first-list variant's](../../variants/first-list/k3s/manifests/traefik-config.yaml) does.

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    ports:
      websecure: null
```

Checked by rendering the Traefik chart that k3s 1.33 ships (`traefik-40.1.4+up40.1.0`) with this config: the entrypoints are `web` on 8000 (Service port 80), `traefik` on 8080 (dashboard, not exposed) and `metrics` on 9100, and the Service has only port 80.

```bash
kubectl get svc traefik -n kube-system -o jsonpath='{.spec.ports[*].port}'   # 80
openssl s_client -connect <node>:443 </dev/null                              # connection refused
```

## A new serving certificate on every server after a CA rotation

**Problem.** Every k3s server serves 6443 with one certificate, which they share through the Secret `k3s-serving` in `kube-system`, each with a copy in `server/tls/dynamic-cert.json`. `k3s certificate rotate-ca` makes only the server it runs on sign that certificate again with the new server CA on its restart: it leaves the marker `server/tls/dynamic-cert-regenerate` there alone. When another server restarts, it can write its copy, of the old CA, back into the Secret: k3s's dynamiclistener prefers a certificate with all the names, whichever CA signed it. Every server then serves the old CA's certificate. In a run of the `ca-rotation` scenario, the second server restarted with the new CAs, wrote its old certificate back, and all three servers switched to it; a client that trusts only the new CA refuses every API server. It happens on some restarts and not others, by which reaches the Secret first. [docs.k3s.io](https://docs.k3s.io/cli/certificate#rotating-self-signed-ca-certificates) only says to restart every server.

**What changes.** Each server signs a new serving certificate with the new server CA on its restart, so whichever copy reaches the Secret is of the new CA.

**How.** After `rotate-ca` succeeds, on every other server, before its restart:

```bash
touch /var/lib/rancher/k3s/server/tls/dynamic-cert-regenerate   # k3s removes it at its next start
```

Then restart k3s on one server after another. Check, on each server:

```bash
openssl s_client -connect <server>:6443 </dev/null 2>/dev/null | openssl x509 -noout -issuer   # the new k3s-server-ca
```

The `ca-rotation` scenario does this and checks each server against the new CAs alone.

## The self-signed certificates that stay

With 443 gone, only the k3s certificates are still on the nodes' addresses: on 6443 (API server), 10250 (kubelet) and 2379-2380 (etcd). A firewall in front of the nodes that lets in only 5432 and 80, and 6443 only from the admins' addresses, keeps them out of a scan. The rest answer only inside the cluster. Replacing them needs certificates for `.svc` names, which an ACME CA that only issues for public names does not give, or turning the component off.

| Component | What is self-signed | Who connects |
|---|---|---|
| k3s | Its server, client, request-header and etcd CAs (10 years), which sign the API server on 6443, the kubelets on 10250 and etcd | Kubernetes components and kubectl |
| metrics-server | Its serving certificate, made at start | The API server (`kubectl top`, HPA) |
| cert-manager | The webhook's CA | The API server |
| CNPG operator | The webhook's CA, and the client certificate it uses on each instance's status port | The API server; the instances |
| barman-cloud plugin | Its gRPC server and client certificates, from a self-signed Issuer | The CNPG operator and the instances |

CNPG makes no CA for the cluster itself when all four of `serverTLSSecret`, `serverCASecret`, `clientCASecret` and `replicationTLSSecret` are given, as the [cluster chart](../../samples/charts/cnpg-cluster/templates/cluster.yaml) does.
