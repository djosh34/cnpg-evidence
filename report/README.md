# report

The page that draws the evidence images, and `cnpg-report`, the one static file that draws them with the Chrome it carries.

The page is plain HTML, one CSS file and plain JS, with no build step. A caller loads `page/index.html` in Chrome, passes it the documents of one script, and saves each sheet the page draws as one PNG.

Each image is one table. A desired image shows the values of a desired document from `scripts/desired/desired.sh`; its actual image shows the values of the script's actual document in the same columns and row order. On the actual image, a value only the actual document has is red, and a desired value it lacks is red and struck through. A difference marks a value, not a failed check: the scripts' own checks stay the verdict, and no image says passed or failed.

## Files

| Path | What it is |
|---|---|
| `page/index.html` | The page; loads the CSS and the three scripts |
| `page/styles.css` | The look of every image |
| `page/compare.js` | The comparison of a desired and an actual document, and the reader the images use |
| `page/images.js` | Every image: file name, words, columns and rows |
| `page/draw.js` | `draw()`: checks the documents, draws the sheets and lines up each pair |
| `page/fonts/` | Sofia Sans, Sofia Sans Semi Condensed and Sofia Sans Condensed, with their licence `OFL.txt` |
| `samples/` | Example documents: desired, clean and failing for each script. All values are invented. |
| `test/` | Unit tests of the comparison and the images, and the test of the built binary |
| `dev/render.js` | Renders every image of the samples with a local Chrome |
| `launcher/` | The Go launcher of `cnpg-report`, its private `fonts.conf`, and `libs.sh`, which gathers the libraries from UBI9 |
| `build.sh` | Builds `cnpg-report` |

## cnpg-report

```
cnpg-report [--desired <file.json>] --out <dir> <file.json>
```

One call draws the images of one document into `<dir>`, which it makes if needed. The source and kind come from the document. An actual document needs its desired document as `--desired`, and the call writes both images of every pair. A desired document of `evidence.sh` or `prove.sh` alone gives its desired images; a host-check desired document is drawn only with a node file.

Exit 0 when every image is written. Exit 2 on unreadable JSON, a missing key, a render error or a wrong call, with no image left in `<dir>`.

```bash
cnpg-report --desired evidence.desired.json --out images/ evidence.json
for node in node-a.json node-b.json; do
  cnpg-report --desired host-check.desired.json --out images/ "$node"
done
```

The file is a static x86_64 Linux executable of about 130 MB. It needs no network and no library or font from the OS; the test below shows this in a stock `ubi9-minimal` container. glibc still reads `/etc/nsswitch.conf` and `/etc/hosts` there. Each call unpacks about 300 MB into a new directory in `TMPDIR` (default `/tmp`), which must allow running files, and removes it after. Chrome runs without its sandbox, so give it only documents of the scripts.

What it carries:

- chrome-headless-shell of [Chrome for Testing](https://googlechromelabs.github.io/chrome-for-testing/), at the version pinned in `build.sh`;
- the libraries Chrome links and opens at run time, glibc and its loader `ld-linux-x86-64.so.2`, all taken from UBI9 RPMs; Chrome starts through that loader, and so do the processes it starts, which run through `cnpg-report` again;
- the page, with its Sofia Sans fonts and a `fonts.conf` that names only them;
- the licence texts in `licenses/`: Chrome for Testing's `LICENSE.headless_shell`, `OFL.txt` of the fonts, Go's licence, and the texts of each RPM in `licenses/rpm/<RPM>/`. An RPM with no licence file of its own gets those at the top of its upstream source, from the UBI9 source RPM. `licenses/rpms.txt` lists every RPM with its version, licence and project URL, and names any RPM with a licence file in neither place. The texts are in the unpacked directory while a call runs.

### Building

On an x86_64 Linux host with network, docker, curl, unzip and sha256sum:

```bash
bash report/build.sh build/cnpg-report
```

It downloads the pinned Chrome zip and checks its SHA-256, installs the RPMs in a pinned UBI9 container and copies their libraries and licence texts, packs the payload, and builds the launcher with `CGO_ENABLED=0` in a pinned Go container. `launcher/payload.tar.gz` exists only during a build, so `go vet` and `go build` in `launcher/` work only inside it.

## Drawing the images

After the page has loaded, the caller runs, as one script evaluation:

```js
await draw(actualDocument, desiredDocument)  // both images of each pair
await draw(desiredDocument)                  // the desired image of each pair
```

`draw()` returns a list of `{file, selector}`. The caller saves the element of each `selector` as a PNG named `file`. Each image has the width of its table plus 88 px margins and the height of its content.

`draw()` throws an `Error` with one line of text, and draws nothing, when:

- a document has no `kind` or `source`, or an unknown `source`;
- an actual document comes without its desired document, or a desired document comes with a second one;
- the two documents are not one desired and one actual document of the same source;
- a section an image reads is missing, such as `tls` in an evidence document;
- `collected_at` is not a UTC time like `2026-01-02T03:04:05Z`, or the host-check `node` is not a node name;
- a host-check desired document comes alone. It holds no node name, so its images are drawn with a node file, which names them.

Both images of a pair take their column widths from the desired table, so a pair lines up whether it was drawn in one call or two. A longer actual value wraps, so rows that differ may differ in height.

## Images

`evidence.sh`, 12 pairs and one actual image:

- `evidence-01-accounts-desired.png`, `evidence-01-accounts-actual.png`
- `evidence-02-certificate-names-desired.png`, `-actual.png`
- `evidence-03-login-rules-desired.png`, `-actual.png`
- `evidence-04-client-ca-desired.png`, `-actual.png`
- `evidence-05-encryption-desired.png`, `-actual.png`
- `evidence-06-network-desired.png`, `-actual.png`
- `evidence-07-container-isolation-desired.png`, `-actual.png`
- `evidence-08-operator-secrets-desired.png`, `-actual.png`
- `evidence-09-platform-pods-desired.png`, `-actual.png`
- `evidence-10-platform-secrets-desired.png`, `-actual.png`
- `evidence-11-platform-setup-desired.png`, `-actual.png`
- `evidence-12-platform-nodes-certificates-desired.png`, `-actual.png`
- `evidence-13-versions-actual.png` only: versions have no desired value.

`host-check.sh`, one pair per check of the node file, named with its `node` and the check `id`:

- `host-check-<node>-<check>-desired.png`, `host-check-<node>-<check>-actual.png`, such as `host-check-node-a-selinux-enforcing-actual.png`. The 13 checks are listed in [host-check.md](../docs/host-check.md#checks).

`prove.sh`, three pairs:

- `prove-01-login-attempts-desired.png`, `-actual.png`: the logins from the node.
- `prove-02-other-namespace-desired.png`, `-actual.png`: the probes whose name contains `other-namespace`.
- `prove-03-host-uid-desired.png`, `-actual.png`: the probes whose name starts with `uid-`.

The network images cover ports 8000 and 9187 and say so; logins on 5432 are in the login images.

## The comparison

`page/compare.js` follows the rule of `scripts/desired/compare.jq`, described in [desired.md](../docs/desired.md#the-comparison): skipped top-level keys and `raw`, allowed sets, `"*"` maps, and rows compared by identity, so an extra row is red, a missing row is struck through, and a moved pg_hba or pg_ident line shows as one missing and one extra row. The tests check that it finds the same differences as `compare.sh` on every sample and on each test case.

## Tests

From `report/`, with Node.js 20 or later, bash and jq:

```bash
node --test test/*.test.js
```

CI runs them in the `page` job.

The built binary, on an x86_64 host with docker and jq:

```bash
bash report/test/binary.sh build/cnpg-report images
```

It runs the binary in `ubi9-minimal` with `--network=none` on the clean, failing and desired samples and compares the written files with the image list above (`test/expected-images.sh`). It checks exit 2 and no output directory on broken JSON and on a missing key. Last, it traces one run with `strace -f -e trace=openat` in a throwaway `ubi9-minimal` image that adds strace, and fails on any open under `/usr/lib64`, `/lib64`, `/usr/share/fonts` or `/etc/fonts`, failed ones included. The images and `strace-summary.txt` go into `images/`. CI runs it in the `report` job and uploads `images/` as the `report-images` artifact.

## Development render

From `report/`, with Node.js and a local Chrome or chrome-headless-shell:

```bash
npm ci
node dev/render.js /path/to/chrome /tmp/report-images
```

It writes every image of the clean and the failing samples to `/tmp/report-images/clean/` and `/tmp/report-images/failing/`, and prints a line for any text that runs past its box. `playwright-core` drives Chrome here only; the page itself needs no package.
