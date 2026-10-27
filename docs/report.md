# cnpg-report

`cnpg-report` draws PNG images from the JSON documents of `evidence.sh`, `host-check.sh` and `prove.sh`. Each piece of evidence gets a pair of images. The desired image shows the values the rules call for, and the actual image shows the values the script found, in the same columns and row order. A reviewer reads the pair side by side.

It is one static x86_64 Linux file of about 130 MB. It carries its own Chrome, glibc, libraries, fonts and the page that draws the images, so it runs with no network and no library or font from the OS, for example in a stock `ubi9-minimal` container. It only draws: the verdict stays the script's `status` and `violations`, and no image says passed or failed.

## Get the binary

The binary is the only file in the image `ghcr.io/djosh34/cnpg-report`, at `/cnpg-report`. The image tags are the release versions, such as `v0.1.0`. The image is for `linux/amd64` only, so on another host add `--platform linux/amd64` to the pull.

With podman (or docker, with the same commands):

```bash
podman pull --platform linux/amd64 ghcr.io/djosh34/cnpg-report:v0.1.0
podman create --name cnpg-report ghcr.io/djosh34/cnpg-report:v0.1.0 /cnpg-report
podman cp cnpg-report:/cnpg-report ./cnpg-report
podman rm cnpg-report
```

`podman create` only makes a container for `podman cp` to copy from; the container never runs.

With skopeo and jq, without a container engine:

```bash
skopeo --override-arch amd64 --override-os linux copy \
  docker://ghcr.io/djosh34/cnpg-report:v0.1.0 dir:cnpg-report-image
layer=$(jq -r '.layers[0].digest | sub("sha256:"; "")' cnpg-report-image/manifest.json)
tar -xf "cnpg-report-image/$layer" cnpg-report
```

The image has one layer, and `dir:` stores it as a file named by its digest. Then copy `cnpg-report` to the host that renders. It runs on any x86_64 Linux; `chmod +x cnpg-report` if the copy lost the mode.

To build it from source instead, see [Building](../report/README.md#building).

## Desired and actual documents

Every script prints an actual document (`"kind": "actual"`), the values it found on the cluster or node. [`desired.sh`](desired.md) builds the desired document (`"kind": "desired"`) of the same shape from `desired.yaml` alone. A pair of images comes from one desired and one actual document of the same script. The actual documents, as in the [README](../README.md#run):

```bash
yq -o=json desired.yaml | bash scripts/evidence/evidence.sh --ca client-ca.pem > evidence.json
bash scripts/host-check/host-check.sh > node-a.json    # on each node
bash scripts/prove/prove.sh > prove.json
```

Their desired documents, anywhere with bash, jq and openssl:

```bash
yq -o=json desired.yaml | bash scripts/desired/desired.sh --ca client-ca.pem > evidence.desired.json
yq -o=json desired.yaml | bash scripts/desired/desired.sh --source host-check > host-check.desired.json
yq -o=json desired.yaml | bash scripts/desired/desired.sh --source prove > prove.desired.json
```

Both documents are plain files, so the scripts can run in one place and `cnpg-report` in another. It reads only the files named in the call.

On an actual image, the values that differ from the desired document are red:

- A value only the actual document has is red.
- A desired value the actual document lacks is red and struck through.

The comparison is the one `compare.sh` makes, described in [desired.md](desired.md#the-comparison). Rows match by their identity, not their place, so an extra row is red, a missing row is struck through, and a pg_hba or pg_ident line that moved shows as one missing and one extra row. Red marks a difference, not a failed check.

## Run

```
cnpg-report [--desired <file.json>] --out <dir> <file.json>
```

One call draws the images of one document into `<dir>`, and makes `<dir>` if needed. The script and the kind come from the document itself. An actual document needs its desired document as `--desired`, and the call writes both images of every pair.

```bash
# evidence.sh: both images of every pair
cnpg-report --desired evidence.desired.json --out images/ evidence.json

# host-check.sh: one call per node file, all against one desired document
for node in node-a.json node-b.json; do
  cnpg-report --desired host-check.desired.json --out images/ "$node"
done

# prove.sh: both images of every pair
cnpg-report --desired prove.desired.json --out images/ prove.json

# evidence.sh and prove.sh desired documents alone: only the desired images
cnpg-report --out images/ evidence.desired.json
cnpg-report --out images/ prove.desired.json
```

A host-check desired document alone is refused. It holds no node name, and the node name is part of every host-check file name, so its desired images come only from a call with a node file.

The images of one pair line up whether they come from one call or two: both take their column widths from the desired table. A longer actual value wraps, so rows that differ may differ in height.

### Exit codes

- `0`: every image is written.
- `2`: an error, with a one-line message on stderr that starts with `cnpg-report:`. No image of this call is left in `<dir>`, and `<dir>` is removed again if the call made it. Errors are a wrong call, a file that is not readable or not JSON, a missing key, an unknown `source`, two documents that are not one desired and one actual document of the same script, a host-check desired document alone, and a render that fails or takes longer than 5 minutes.

`cnpg-report` prints nothing on success. Files already in `<dir>` stay, and an image with the same name is replaced.

### Space and TMPDIR

Each call unpacks about 300 MB into a new directory under `TMPDIR` (default `/tmp`) and removes it when the call ends, also on an error, Ctrl-C or `SIGTERM`. That directory must have the space free, and its file system must allow running files, so not one mounted `noexec`:

```bash
TMPDIR=/var/tmp cnpg-report --desired evidence.desired.json --out images/ evidence.json
```

Chrome runs without its sandbox, so give `cnpg-report` only documents of the three scripts. glibc still reads `/etc/nsswitch.conf` and `/etc/hosts` from the OS.

## Output file names

Each image is one PNG, named after the script, the piece of evidence and the side.

`evidence.sh`, 12 pairs and one actual image:

| Image | Files |
|---|---|
| Accounts | `evidence-01-accounts-desired.png`, `evidence-01-accounts-actual.png` |
| Certificate names | `evidence-02-certificate-names-desired.png`, `evidence-02-certificate-names-actual.png` |
| Login rules | `evidence-03-login-rules-desired.png`, `evidence-03-login-rules-actual.png` |
| Client CA | `evidence-04-client-ca-desired.png`, `evidence-04-client-ca-actual.png` |
| Encryption | `evidence-05-encryption-desired.png`, `evidence-05-encryption-actual.png` |
| Network | `evidence-06-network-desired.png`, `evidence-06-network-actual.png` |
| Container isolation | `evidence-07-container-isolation-desired.png`, `evidence-07-container-isolation-actual.png` |
| Operator Secrets | `evidence-08-operator-secrets-desired.png`, `evidence-08-operator-secrets-actual.png` |
| Platform pods | `evidence-09-platform-pods-desired.png`, `evidence-09-platform-pods-actual.png` |
| Platform Secrets | `evidence-10-platform-secrets-desired.png`, `evidence-10-platform-secrets-actual.png` |
| Platform setup | `evidence-11-platform-setup-desired.png`, `evidence-11-platform-setup-actual.png` |
| Nodes and certificates | `evidence-12-platform-nodes-certificates-desired.png`, `evidence-12-platform-nodes-certificates-actual.png` |
| Versions | `evidence-13-versions-actual.png` only, since versions have no desired value |

The network images cover the status and metrics ports, 8000 and 9187, and say so. Logins on 5432 are in the login images.

`host-check.sh`, one pair per check of the node file, named with the document's `node` and the check's `id`:

- `host-check-<node>-<check>-desired.png` and `host-check-<node>-<check>-actual.png`, such as `host-check-node-a-selinux-enforcing-actual.png`. The 13 checks are listed in [host-check.md](host-check.md#checks).

`prove.sh`, three pairs:

| Image | Files |
|---|---|
| Logins from the node | `prove-01-login-attempts-desired.png`, `prove-01-login-attempts-actual.png` |
| Connections from another namespace | `prove-02-other-namespace-desired.png`, `prove-02-other-namespace-actual.png` |
| Access as the host postgres uid | `prove-03-host-uid-desired.png`, `prove-03-host-uid-actual.png` |

Each image is as wide as its table plus 88 px margins, and as high as its content. Its header gives the title, the control, a Desired or Actual tag, the cluster or node, and who made the document. An actual image adds the collection time and a key to the red marks.

## Third-party parts and their licences

The binary carries:

- chrome-headless-shell of [Chrome for Testing](https://googlechromelabs.github.io/chrome-for-testing/), at the version pinned in `report/build.sh`, under its `LICENSE.headless_shell`.
- glibc, its loader `ld-linux-x86-64.so.2` and the libraries Chrome needs, all from UBI9 RPMs, each under the licence texts of its RPM.
- The Sofia Sans, Sofia Sans Semi Condensed and Sofia Sans Condensed fonts, under the SIL Open Font License (`OFL.txt`).
- The Go runtime and standard library, under Go's licence.

The texts are in `licenses/` of the directory a call unpacks, while it runs. `licenses/rpms.txt` lists every RPM with its version, licence and project URL, and `licenses/rpm/<RPM>/` holds its texts. An RPM with no licence file of its own gets the licence files at the top of its upstream source, from the UBI9 source RPM. `cnpg-report` itself is under the Apache License 2.0 of this repository.

## More

[report/README.md](../report/README.md) describes the page, the comparison code, the build, and the tests of the page and the binary.
