{{- /*
An Issuer of the ACME CA, with its own ACME account, for one Certificate of
the same name. Called with (dict "name" <name> "namespace" <namespace> "acme"
.Values.acme). The EAB key is in the Secret <name>-acme-eab; cert-manager
uses it only to register the account and keeps the account key in
<name>-acme-account.
*/}}
{{- define "cnpg-cluster.issuer" -}}
{{- $eabName := printf "%s-acme-eab" .name }}
{{- $eab := lookup "v1" "Secret" .namespace $eabName }}
{{- if not $eab }}
{{- fail (printf "the Secret %s with the EAB key (keyID and secret) is missing in %s" $eabName .namespace) }}
{{- end -}}
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: {{ .name }}
  namespace: {{ .namespace }}
spec:
  acme:
    server: {{ .acme.server }}
    {{- with .acme.caSecret }}
    {{- $ca := lookup "v1" "Secret" $.namespace . }}
    caBundle: {{ required (printf "the Secret %s with ca.crt is missing" .) (dig "data" "ca.crt" "" $ca) }}
    {{- end }}
    privateKeySecretRef:
      name: {{ .name }}-acme-account
    externalAccountBinding:
      keyID: {{ dig "data" "keyID" "" $eab | b64dec }}
      keySecretRef:
        name: {{ $eabName }}
        key: secret
    solvers:
      - http01:
          ingress:
            ingressClassName: {{ .acme.ingressClassName }}
{{- end }}
