# Certificates

## One Issuer per Certificate

**Problem.** cert-manager orders every certificate of an Issuer or ClusterIssuer through that Issuer's one ACME account. When several certificates share an account, an ACME server can time out their orders.

**What changes.** Each Certificate has its own namespaced Issuer, and so its own ACME account. Orders never wait on another certificate's account. There is no shared ClusterIssuer for them.

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

cert-manager uses the external account binding only to register the account. Afterwards the account key in `privateKeySecretRef` is enough, so an EAB key that is valid for a short time works. If that account key Secret is lost, cert-manager registers a new account and needs a valid EAB key again. The [cluster chart](../../samples/charts/cnpg-cluster) has one `issuer` value for both of its Certificates; give each its own.

Check that every Certificate names its own Issuer:

```bash
kubectl get certificate -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,KIND:.spec.issuerRef.kind,ISSUER:.spec.issuerRef.name
```

## No port 443 on Traefik

**Problem.** k3s's Traefik listens on 443 of every node and, with no certificate configured for it, answers with its own self-signed `TRAEFIK DEFAULT CERT`. A scan of the nodes flags it.

**What changes.** Traefik listens on port 80 only. cert-manager's http-01 challenges need nothing else, and k3s's Traefik does not redirect 80 to 443. Traefik still builds its default certificate in memory; it is served only if someone adds a TLS route (an IngressRoute with `tls`, or an Ingress with `traefik.ingress.kubernetes.io/router.tls`), so who may write routes decides that.

**How.** On every server, in `/var/lib/rancher/k3s/server/manifests/traefik-config.yaml` (as in [`samples/k3s/manifests/`](../../samples/k3s/manifests)):

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

Checked by rendering the Traefik chart that k3s 1.33 ships with this config: the entrypoints are 80, 8080 (dashboard, not exposed) and 9100 (metrics), and the Service has only port 80.

```bash
kubectl get svc traefik -n kube-system -o jsonpath='{.spec.ports[*].port}'   # 80
openssl s_client -connect <node>:443 </dev/null                              # connection refused
```

## The self-signed certificates that stay

With 443 gone, none of these is reachable from outside the cluster. Each answers only the API server, the kubelet, etcd or CNPG's own components. Replacing them needs certificates for `.svc` names, which an ACME CA does not issue, or turning the component off.

| Component | What is self-signed | Who connects |
|---|---|---|
| k3s | Its server, client, request-header and etcd CAs (10 years), which sign the API server on 6443, the kubelets on 10250 and etcd | Kubernetes components and kubectl |
| metrics-server | Its serving certificate, made at start | The API server (`kubectl top`, HPA) |
| cert-manager | The webhook's CA | The API server |
| CNPG operator | The webhook's CA, and the client certificate it uses on each instance's status port | The API server; the instances |
| barman-cloud plugin | Its gRPC server and client certificates, from a self-signed Issuer | The CNPG operator and the instances |

CNPG makes no CA for the cluster itself when all four of `serverTLSSecret`, `serverCASecret`, `clientCASecret` and `replicationTLSSecret` are given, as the [cluster chart](../../samples/charts/cnpg-cluster/templates/cluster.yaml) does.
