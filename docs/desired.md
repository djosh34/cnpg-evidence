# desired.sh

`scripts/desired/desired.sh` builds the desired document of `evidence.sh`, `host-check.sh` or `prove.sh` from [`desired.yaml`](../desired.yaml) alone. A desired document has the shape of the script's actual output, so the two can be compared. It needs no cluster, host or network access.

`cnpg-report` compares a desired with an actual document, as [report.md](report.md#the-comparison) describes. A difference is not a failed check: the actual document's `status`, `ok` and `violations` stay the verdict.

## Run

Anywhere with bash, `jq` and `openssl`:

```bash
yq -o=json desired.yaml | bash scripts/desired/desired.sh --ca client-ca.pem > evidence.desired.json
yq -o=json desired.yaml | bash scripts/desired/desired.sh --source host-check > host-check.desired.json
yq -o=json desired.yaml | bash scripts/desired/desired.sh --source prove > prove.desired.json
```

- stdin: the desired values from `desired.yaml` as JSON, as for `evidence.sh`. They must have every key `evidence.sh` needs, for every source.
- `--source`: `evidence` (default), `host-check` or `prove`.
- `--ca`: for `evidence` only, and needed there: the same CA certificates as `evidence.sh --ca`.
- `--postgres-uid`: for `prove` only, PostgreSQL's uid in the CNPG image, as `prove.sh --postgres-uid`. Default 26.

`desired.sh` prints one JSON document; exit 0, or 2 on any error, with nothing on stdout.

## Where the desired values come from

- **evidence:** every expected value that `evidence.sh` checks against is in `scripts/evidence/violations/expected.jq`: the fixed CNPG roles and their rights, the databases, the pg_hba and pg_ident lines and the certificate logins they give, the TLS minimum, the allowed Kubernetes subjects and the Secret namespaces of the operator and the plugin. The violation sections and `desired.sh` both read this file, so the checks and the desired document cannot disagree.
- **host-check:** each check with the value it has when it passes, as in the table in [host-check.md](host-check.md#checks). `checks.test.sh` checks that the list has every check of `host-check.sh` in its order.
- **prove:** each probe with the text `prove.sh` writes for it and the value it has when it passes. The application login is the first database of `desired.yaml`, whose pg_hba line the sample chart writes first. The login and uid tests check that the names, texts and values match.

## Output

The desired documents start with `kind: desired` and `source`. They have no `collected_at`, `status` or `violations`. Values that only a live run can know are left out: the instance pod names, the primary and the versions in the evidence document, the node and the collected host facts in the host-check document, the node and the `raw` attempts in the prove document. Example, shortened and shown as YAML:

```yaml
kind: desired
source: evidence
cluster: {name: pg, namespace: databases}
postgres: {superusers: [postgres], have_password: [], roles: [billing, cnpg_metrics_exporter, orders, postgres, streaming_replica], databases: [billing, orders, postgres, template0, template1], ...}
certificate_logins: [{common_name: orders-app.test, role: orders, database: orders}, ...]
client_ca: {secret: client-ca, certificates: [{name: CN=example-ca, sha256_fingerprint: "2E:18:..."}]}
tls: {"*": {postgresql: TLSv1.3, metrics: TLSv1.3}}
kubernetes: {superuser_in_cluster_namespace: {allowed: [group:system:masters, ...]}, run_pods: {allowed: [...]}, ...}
pods_sharing_host_uids: []
details: {pg_hba: [{number: 1, line: local all cnpg_metrics_exporter peer map=cnpg_metrics_exporter}, ...], pg_ident: [...]}
```

Two forms appear only in desired documents:

- `{"allowed": [...]}` in place of a list: an allowed set. The actual list may hold any of these members and no other; a member it lacks, or a missing list, is no difference. Used for the Kubernetes subjects of every right, the namespaces where the operator and the plugin may read Secrets, and `not_served`, which is absent on a cluster with Traefik. Every other list is exact.
- A map with the one key `"*"`: the value every key of the actual map must have. Used where only a live cluster knows the keys: the instance pods in `tls`.

The pg_hba and pg_ident lines are CNPG 1.30's fixed lines around the lines the sample chart writes, as the `pg_hba_file_rules` and `pg_ident_file_mappings` views show them, numbered in matching order.

## Code

| Path | What it does |
|---|---|
| `desired.sh` | Reads the input and prints one desired document |
| `evidence.jq` | The desired evidence document, from `scripts/evidence/violations/expected.jq` |
| `host-check.jq`, `prove.jq` | The desired host-check and prove documents |

`desired.test.sh` covers `desired.sh` and the three `.jq` documents; `scripts/test.sh` runs it with the other tests.

## Limits

- A difference marks a value, not a broken rule. A check can pass with a value the desired document does not name, such as a metrics TLS version other than TLSv1.3, or fewer holders of a Kubernetes right than allowed; the comparison shows the first as a difference.
- The pg_hba and pg_ident lines follow CNPG 1.30. Another CNPG version may write other fixed lines, which then show as differences.
- The host-check document is the same for every node.
