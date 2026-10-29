# report

The page that draws the evidence images, and `cnpg-report`, the one static file that draws them with the Chrome it carries.

How to get, run and read `cnpg-report` is in [report.md](../docs/report.md). This file is about the code.

The page is plain HTML, one CSS file and plain JS, with no build step. A caller loads `page/index.html` in Chrome, passes it the documents of one script, and saves each sheet the page draws as one PNG.

Each image is one table. A desired image shows the values of a desired document from `scripts/desired/desired.sh`; its actual image shows the values of the script's actual document in the same columns. Every yes or no is a square. On the actual image, a value or held right beyond the desired document is red, an extra row has a red name, and a protection that is off is a red empty square. What the actual document lacks is not drawn. Each actual image says Failed when it shows a red mark and Passed when it shows none, and each image has a legend of the marks it can show. [report.md](../docs/report.md#reading-the-images) describes the marks for the reader.

## Files

| Path | What it is |
|---|---|
| `page/index.html` | The page; loads the CSS and the three scripts |
| `page/styles.css` | The look of every image |
| `page/compare.js` | The comparison of a desired and an actual document, and the reader the images use |
| `page/images.js` | Every image: file name, words, columns, legend and rows |
| `page/draw.js` | `draw()`: checks the documents, leaves out what actual lacks, orders the rows, sets Passed or Failed, draws the sheets and lines up each pair |
| `page/fonts/` | Sofia Sans, Sofia Sans Semi Condensed and Sofia Sans Condensed, with their licence `OFL.txt` |
| `samples/` | Example documents: desired, clean and failing for each script, the desired values `desired-values.json` and the CA `client-ca.pem` the desired documents come from. All values are invented. |
| `test/` | Unit tests of the comparison and the images, and the test of the built binary |
| `dev/render.js` | Renders every image of the samples with a local Chrome |
| `launcher/` | The Go launcher of `cnpg-report`, its private `fonts.conf`, and `libs.sh`, which gathers the libraries from UBI9 |
| `build.sh` | Builds `cnpg-report` |

## cnpg-report

`cnpg-report` is a static x86_64 Linux file of about 130 MB. [report.md](../docs/report.md) describes its call, exit codes, space needs and the parts it carries with their licences. Chrome starts through the loader it carries, and so do the processes Chrome starts, which run through `cnpg-report` again. The page uses its Sofia Sans fonts through a `fonts.conf` that names only them, and the licence texts go into `licenses/` of the payload.

### Building

On an x86_64 Linux host with network, docker, curl, unzip and sha256sum:

```bash
bash report/build.sh build/cnpg-report
```

It downloads the pinned Chrome zip and checks its SHA-256, installs the RPMs in a pinned UBI9 container and copies their libraries and licence texts, packs the payload, and builds the launcher with `CGO_ENABLED=0` in a pinned Go container. `launcher/payload.tar.gz` exists only during a build, so `go vet` and `go build` in `launcher/` work only inside it.

A pushed tag `v*` runs `.github/workflows/release.yml`. It runs every CI job, then pushes the binary the `report` job built and tested as `ghcr.io/djosh34/cnpg-report:<tag>`, an image `FROM scratch` with only `/cnpg-report` in it. A last job pulls that image, copies the binary out with `podman create` and `podman cp`, renders the clean samples with it, and runs the container example of [report.md](../docs/report.md#in-a-container) on the image.

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

`evidence.sh`, 8 pairs and one actual image:

- `evidence-01-accounts-desired.png`, `evidence-01-accounts-actual.png`: with the certificate names that log in as each account and the databases their certificate pg_hba lines name.
- `evidence-02-certificate-logins-desired.png`, `-actual.png`: each certificate name, its account and the database its pg_hba line names, then each database no certificate pg_hba line names.
- `evidence-03-login-rules-desired.png`, `-actual.png`
- `evidence-04-client-ca-desired.png`, `-actual.png`
- `evidence-05-encryption-desired.png`, `-actual.png`
- `evidence-06-container-isolation-desired.png`, `-actual.png`
- `evidence-07-operator-secrets-desired.png`, `-actual.png`
- `evidence-08-platform-rights-desired.png`, `-actual.png`
- `evidence-09-versions-actual.png` only: versions have no desired value.

`host-check.sh`, one pair per check of the node file, named with its `node` and the check `id`:

- `host-check-<node>-<check>-desired.png`, `host-check-<node>-<check>-actual.png`, such as `host-check-node-a-selinux-actual.png`. The six checks are listed in [host-check.md](../docs/host-check.md#checks).

`prove.sh`, two pairs:

- `prove-01-login-attempts-desired.png`, `-actual.png`: the logins from the node.
- `prove-02-host-uid-desired.png`, `-actual.png`: the probes whose name starts with `uid-`.

## The comparison

`page/compare.js` follows the rule described in [report.md](../docs/report.md#the-comparison): skipped top-level keys and `raw`, allowed sets, `"*"` maps, and rows compared by identity. The tests check that it finds no difference on the clean samples and the expected differences on each test case.

The images then apply the rules of the report on top of those differences:

- `draw.js` leaves out every row and value that only the desired document has.
- A square is red when its right is held and the comparison found it extra. An allowed right that is not held stays a normal empty square. The container isolation square is a protection: a pod that shares the host's ids is a red empty square.
- An extra row is red only in the cells that name it. On the platform images an account counts as extra when the desired document lists it for none of the image's rights.
- `draw.js` puts the correct rows first and the rows with a red mark last, each group sorted by its cells from the first column on, and sorts the values of each cell the same way. A row with a `section` sorts within that part of the table: pg_ident lines come after the pg_hba lines, and the databases no certificate pg_hba line names after the certificate logins. pg_hba rows keep their line-number order. pg_ident lines are compared as a list without numbers, so only a line the desired document lacks is red.
- A host-check value of `true` or `false` is a square. prove.sh joins the different results of one attempt with `, `, and each is drawn as a value of its own.
- An actual image is Failed when any value on it is red, else Passed.

## Tests

From `report/`, with Node.js 20 or later, bash, jq and openssl:

```bash
node --test test/*.test.js
```

CI runs them in the `page` job. `test/samples.test.js` checks that each `samples/*.desired.json` is what `scripts/desired/desired.sh` prints for `samples/desired-values.json` and `samples/client-ca.pem`; after a change to the scripts, write them again with it.

The built binary, on an x86_64 host with docker and jq:

```bash
bash report/test/binary.sh build/cnpg-report images
```

It runs the binary in `ubi9-minimal` with `--network=none` on the clean, failing and desired samples and compares the written files with the image list above (`test/expected-images.sh`). It checks exit 2 and no output directory on broken JSON and on a missing key. Last, it traces one run with `strace -f -e trace=openat` in a throwaway `ubi9-minimal` image that adds strace, and fails on any open under `/usr/lib64`, `/lib64`, `/usr/share/fonts` or `/etc/fonts`, failed ones included. The images and `strace-summary.txt` go into `images/`. CI runs it in the `report` job and uploads `images/` as the `report-images` artifact.

The container example of [report.md](../docs/report.md#in-a-container), on an x86_64 host with docker and jq:

```bash
bash report/test/docker-example.sh VERSION OUT_DIR
```

It takes the command from the docs as written, runs it with the image `ghcr.io/djosh34/cnpg-report:VERSION` on the evidence samples, and compares the images with the list above. The `report` job builds a local image tagged `ci` from the binary and runs it; the release runs it on the pushed image.

## Development render

From `report/`, with Node.js and a local Chrome or chrome-headless-shell:

```bash
npm ci
node dev/render.js /path/to/chrome /tmp/report-images
```

It writes every image of the clean and the failing samples to `/tmp/report-images/clean/` and `/tmp/report-images/failing/`, and prints a line for any text that runs past its box. `playwright-core` drives Chrome here only; the page itself needs no package.
