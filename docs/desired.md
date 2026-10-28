# desired.sh and compare.sh

`scripts/desired/desired.sh` builds the desired document of `evidence.sh`, `host-check.sh` or `prove.sh` from [`desired.yaml`](../desired.yaml) alone. A desired document has the shape of the script's actual output, so the two can be compared. It needs no cluster, host or network access.

`scripts/desired/compare.sh` lists the literal differences between a desired and an actual document. A difference is not a failed check: the actual document's `status`, `ok` and `violations` stay the verdict.

## Run

Anywhere with bash, `jq` and `openssl`:

```bash
yq -o=json desired.yaml | bash scripts/desired/desired.sh --ca client-ca.pem > evidence.desired.json
yq -o=json desired.yaml | bash scripts/desired/desired.sh --source host-check > host-check.desired.json
yq -o=json desired.yaml | bash scripts/desired/desired.sh --source prove > prove.desired.json

bash scripts/desired/compare.sh evidence.desired.json evidence.actual.json
```

- stdin: the desired values from `desired.yaml` as JSON, as for `evidence.sh`. They must have every key `evidence.sh` needs, for every source.
- `--source`: `evidence` (default), `host-check` or `prove`.
- `--ca`: for `evidence` only, and needed there: the same CA certificates as `evidence.sh --ca`.
- `--postgres-uid`: for `prove` only, PostgreSQL's uid in the CNPG image, as `prove.sh --postgres-uid`. Default 26.

`desired.sh` prints one JSON document; exit 0, or 2 on any error, with nothing on stdout. `compare.sh` prints one JSON list; exit 0, also when the list is not empty, or 2 on any error, such as two actual documents or documents of two sources.

## Where the desired values come from

- **evidence:** every expected value that `evidence.sh` checks against is in `scripts/evidence/violations/expected.jq`: the fixed CNPG roles and their rights, the databases and their logins, the pg_hba and pg_ident lines, the TLS minimum, the network sources and ports, the Services that may reach the instance pods, the allowed Kubernetes subjects and the Secret namespaces of the operator and the plugin. The violation sections and `desired.sh` both read this file, so the checks and the desired document cannot disagree.
- **host-check:** each check with the value it has when it passes, as in the table in [host-check.md](host-check.md#checks). `checks.test.sh` checks that the list has every check of `host-check.sh` in its order.
- **prove:** each probe with the text `prove.sh` writes for it and the value it has when it passes. The application login is the first database of `desired.yaml`, whose pg_hba line the sample chart writes first. The login, pod and uid tests check that the names, texts and values match.

## Output

The desired documents start with `kind: desired` and `source`. They have no `collected_at`, `status` or `violations`. Values that only a live run can know are left out: the instance pod names, the primary and the versions in the evidence document, the node and the collected host facts in the host-check document, the node and the `raw` attempts in the prove document. Example, shortened and shown as YAML:

```yaml
kind: desired
source: evidence
cluster: {name: pg, namespace: databases}
postgres: {superusers: [postgres], have_password: [], roles: [billing, cnpg_metrics_exporter, orders, postgres, streaming_replica], ...}
databases: {orders: {owner: orders, connect: [PUBLIC, orders], logins: {orders: {common_names: [orders-app.test]}, ...}}, ...}
client_ca: {secret: client-ca, certificates: [{name: CN=example-ca, sha256_fingerprint: "2E:18:..."}]}
tls: {"*": {postgresql: TLSv1.3, metrics: TLSv1.3}}
network_policy: {"*": {outside: [5432], other nodes: [5432], own node: [all], ...}}
ports: {services: {databases/pg-rw-lb: {type: LoadBalancer, selector: "cnpg.io/cluster=pg,cnpg.io/instanceRole=primary", ...}, ...}, host_ports: {"*": []}}
kubernetes: {namespaces: {databases: {exec_into_pods: {allowed: [group:system:masters, ...]}, read_secret: {"*": {allowed: [...]}}, ...}}, ...}
pods_sharing_host_uids: []
host_network_pods_that_can_bind_low_ports: []
details: {pg_hba: [{number: 1, line: local all cnpg_metrics_exporter peer map=cnpg_metrics_exporter}, ...], pg_ident: [...], ...}
```

Two forms appear only in desired documents:

- `{"allowed": [...]}` in place of a list: an allowed set. The actual list may hold any of these members and no other; a member it lacks, or a missing list, is no difference. Used for the Kubernetes subjects of every right, the namespaces where the operator and the plugin may read Secrets, and `not_served`, which is shorter or absent on a cluster with Traefik. Every other list is exact.
- A map with the one key `"*"`: the value every key of the actual map must have. Used where only a live cluster knows the keys: the instance pods in `tls`, `network_policy` and `ports.host_ports`, and the Secret names under `read_secret` and `write_secret`.

The evidence document gives `connect` as PostgreSQL's default, `PUBLIC` and the owner; `evidence.sh` reports it but does not check it. The pg_hba and pg_ident lines are CNPG 1.30's fixed lines around the lines the sample chart writes, as the `pg_hba_file_rules` and `pg_ident_file_mappings` views show them, numbered in matching order.

## The comparison

`compare.sh` walks both documents from the top:

- **Skipped:** the top-level `kind`, `source`, `collected_at`, `cluster`, `node`, `status` and `violations`; `details.primary` and `details.instances`; every `raw` key; and every top-level section the desired document lacks, such as `software` and `collected`.
- **Maps** are compared key by key. A key only the actual map has is extra, unless the desired map has `"*"`; a key only the desired map has is missing.
- **Lists** are rows, compared by identity: a row's `id` or `probe`, else the whole row without `raw`. A row only the actual list has is extra, a row only the desired list has is missing, and two rows with the same `id` or `probe` are compared key by key. The order of rows does not count; pg_hba and pg_ident rows carry their number, so a moved line shows as missing and extra rows.
- **Values** that differ show both: the actual value as extra, the desired value as missing.

Each difference is `{path, extra}` or `{path, missing}`. `path` names the keys down to the value, and for a row in a list, its `id` or `probe`:

```json
[{"path": ["postgres", "have_password"], "extra": "orders"},
 {"path": ["kubernetes", "namespaces", "databases", "run_pods"], "extra": "mallory"},
 {"path": ["checks", "selinux-enforcing", "value"], "extra": "disabled"},
 {"path": ["checks", "selinux-enforcing", "value"], "missing": "enforcing"}]
```

An empty list means the actual document has every desired value and nothing else. A `"*"` map stands for the keys the actual map has, so an actual map with no keys shows no difference; `evidence.sh` checks the number of instance pods.

## Code

| Path | What it does |
|---|---|
| `desired.sh` | Reads the input and prints one desired document |
| `evidence.jq` | The desired evidence document, from `scripts/evidence/violations/expected.jq` |
| `host-check.jq`, `prove.jq` | The desired host-check and prove documents |
| `compare.sh`, `compare.jq` | The comparison |

`desired.test.sh` covers `desired.sh` and the three `.jq` documents, `compare.test.sh` covers the comparison; `scripts/test.sh` runs them all.

## Limits

- A difference marks a value, not a broken rule. A check can pass with a value the desired document does not name, such as a metrics TLS version other than TLSv1.3, another `CONNECT` grant or an added pg_hba line that lets no one in; the comparison shows these as differences.
- The pg_hba and pg_ident lines follow CNPG 1.30. Another CNPG version may write other fixed lines, which then show as differences.
- The host-check document is the same for every node.
