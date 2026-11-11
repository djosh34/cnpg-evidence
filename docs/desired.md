# desired.sh

`scripts/desired/desired.sh` builds the desired document of `evidence.sh`, `host-check.sh` or `prove.sh` from `samples/desired.yaml` alone, with no cluster or network. It has the shape of the script's own output, so [`cnpg-report`](report.md) can draw the two side by side. The scripts' own checks stay the verdict.

```bash
yq -o=json samples/desired.yaml | bash scripts/desired/desired.sh --ca client-ca.pem > evidence.desired.json
yq -o=json samples/desired.yaml | bash scripts/desired/desired.sh --source host-check > host-check.desired.json
yq -o=json samples/desired.yaml | bash scripts/desired/desired.sh --source prove > prove.desired.json
```

- `--source`: `evidence` (default), `host-check` or `prove`.
- `--ca`: for `evidence`, the same file as `evidence.sh --ca`.
- `--postgres-uid`: for `prove`, the same as `prove.sh --postgres-uid`. Default 999.
- Needs bash, `jq` and `openssl`. Exit 0, or 2 on any error with nothing on stdout.

The evidence values come from `scripts/evidence/violations/expected.jq`, which the checks of `evidence.sh` read too. The host-check values are the passing values of [its checks](host-check.md#checks), and the prove values those of [its probes](prove.md#probes).

A desired document has `kind: desired` and no `collected_at`, `status` or `violations`. It leaves out what only a live run knows, such as pod names and versions. Two forms appear only here:

- `{"allowed": [...]}`: the actual list may hold any of these and no other. Used for the Kubernetes subjects and the Secret namespaces of the operator and plugin.
- A map with the one key `"*"`: the value every key of the actual map must have, such as each instance's TLS versions.

The pg_hba and pg_ident lines follow CNPG 1.30; another version's fixed lines show as differences.
