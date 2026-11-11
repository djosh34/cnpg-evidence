# cnpg-report

`cnpg-report` draws the JSON documents of `evidence.sh`, `host-check.sh` and `prove.sh` as PNG images: for each piece of evidence, a desired image with the values the rules call for, and an actual image with what the script found, in the same columns. Each actual image says **Passed** or **Failed**, the script's own verdict.

It is one static x86_64 Linux file of about 130 MB, with its own Chrome, glibc, libraries, fonts and page. It runs with no network and no library or font of the OS, such as in a stock `ubi9-minimal`. Chrome runs without its sandbox, so give it only documents of the three scripts. [report/README.md](../report/README.md) describes the code and the build.

## Get the binary

The binary is the only file of the public image `ghcr.io/djosh34/cnpg-report:<version>`, for `linux/amd64` only. Set the version once:

```bash
version=vX.Y.Z   # the release you took the scripts from
podman pull --platform linux/amd64 "ghcr.io/djosh34/cnpg-report:$version"
podman create --platform linux/amd64 --name cnpg-report "ghcr.io/djosh34/cnpg-report:$version" /cnpg-report
podman cp cnpg-report:/cnpg-report ./cnpg-report
podman rm cnpg-report
```

docker takes the same commands. Without a container engine, `skopeo copy` the image to `dir:` and untar its one layer. Put `cnpg-report` on `PATH` of any x86_64 Linux host.

## Run

```
cnpg-report [--desired <desired.json>] --out <dir> <file.json>
```

One call draws one document into `<dir>`. An actual document needs its [desired document](desired.md) as `--desired` and gives both images of each pair; a desired document alone gives only the desired images. Flags come before the file.

```bash
cnpg-report --desired evidence.desired.json --out images/ evidence.json
cnpg-report --desired prove.desired.json --out images/ prove.json
for node in node-a.json node-b.json; do   # one host-check file per node
  cnpg-report --desired host-check.desired.json --out images/ "$node"
done
```

A host-check desired document alone is refused, since the node name is part of every host-check file name.

Exit 0: every image is written. 2: an error, with one line on stderr that starts with `cnpg-report:`. The images are written to hidden files first and renamed only when all are written, so a failed call leaves older images in `<dir>` as they were. Each call unpacks about 300 MB under `TMPDIR` (default `/tmp`), which must allow running files, and removes it at the end.

### In a container

The image runs `cnpg-report` directly. Put the documents in `report-input/`, here `evidence.json` and `evidence.desired.json`, then:

```bash
mkdir -p images
docker run --rm --platform linux/amd64 --network none --user "$(id -u):$(id -g)" \
  --tmpfs /tmp:exec,mode=1777 \
  -v "$PWD/report-input:/in:ro" -v "$PWD/images:/out" \
  "ghcr.io/djosh34/cnpg-report:$version" \
  /cnpg-report --desired /in/evidence.desired.json --out /out /in/evidence.json
```

The images land in `images/`, owned by you. podman takes the same command. CI and the release run this exact block on the samples.

## Read the images

- Every yes or no is a square: filled when the right is held, empty when not.
- **Red** marks what goes beyond the desired document: a held right it does not allow, a value it does not have, or the name of a row it lacks. A protection that is off, such as a pod sharing the host's uids, is a red empty square.
- What the desired document has and the actual one lacks is not drawn.
- Correct rows come first, rows with a red mark last, each group in alphabetical order. pg_hba lines keep their line order, and a moved line is red at its new number; pg_ident lines are compared without numbers.

The verdict is the script's: an evidence image fails when a violation's `path` points at a value it shows, a host-check image when its check has `ok: false`, a prove image when one of its attempts has `ok: false`. Desired images and the Versions image have no verdict.

### The comparison

`report/page/compare.js` walks both documents from the top. It skips the top-level `kind`, `source`, `collected_at`, `cluster`, `node`, `status` and `violations`, `details.primary` and `details.instances`, every `raw` key, and every top-level section the desired document lacks. Maps are compared key by key, and a `"*"` key stands for every key. Lists are rows matched by `id` or `probe`, else by the whole row without `raw`; their order does not count. An `{"allowed": [...]}` list allows any of its members and no other. Each difference is `{path, extra}` or `{path, missing}`.

## Image files

| Script | Files |
|---|---|
| `evidence.sh` | `evidence-NN-<name>-desired.png` and `-actual.png` for `01-accounts`, `02-certificate-logins`, `03-login-rules`, `04-client-ca`, `05-encryption`, `06-container-isolation`, `07-operator-secrets`, `08-platform-rights`; and `evidence-09-versions-actual.png` only |
| `host-check.sh` | `host-check-<node>-<check>-desired.png` and `-actual.png` for each [check](host-check.md#checks) |
| `prove.sh` | `prove-01-login-attempts-` and `prove-02-host-uid-` `desired.png` and `actual.png` |

Each image is as wide as its table plus 88 px margins. Its header gives the title, Desired or Actual, the cluster or node and, on an actual image, the collection time and the verdict.

## Licences

The binary carries chrome-headless-shell of Chrome for Testing under its `LICENSE.headless_shell`, glibc and Chrome's libraries from UBI9 RPMs under their licences, the Sofia Sans fonts under the SIL Open Font License, and the Go runtime under Go's licence. Each call unpacks the texts into `licenses/`; `licenses/rpms.txt` lists every RPM with its version, licence and URL. `cnpg-report` itself is under the Apache License 2.0.
