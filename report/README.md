# report

The page that draws the evidence images, and `cnpg-report`, the one static file that draws them with the Chrome it carries. How to get, run and read `cnpg-report` is in [docs/report.md](../docs/report.md); this file is about the code.

| Path | What |
|---|---|
| `page/index.html`, `page/styles.css` | The page, plain HTML, CSS and JS with no build step |
| `page/compare.js` | The [comparison](../docs/report.md#the-comparison) of a desired and an actual document |
| `page/images.js` | Every image: file name, words, columns, legend and rows |
| `page/draw.js` | `draw()`: checks the documents, leaves out what actual lacks, orders the rows, sets the verdict, draws the sheets |
| `page/fonts/` | The Sofia Sans fonts and their licence `OFL.txt` |
| `samples/` | Invented example documents: desired, clean and failing per script, and the values and CA they come from |
| `test/` | Unit tests of the page, and the tests of the built binary |
| `dev/render.js` | Renders every sample image with a local Chrome |
| `launcher/` | The Go launcher, its `fonts.conf`, and `libs.sh`, which gathers the libraries from UBI9 |
| `build.sh` | Builds `cnpg-report` |

## The page

A caller loads `page/index.html` in Chrome and runs, as one script evaluation:

```js
await draw(actualDocument, desiredDocument)  // both images of each pair
await draw(desiredDocument)                  // the desired image of each pair
```

`draw()` returns a list of `{file, selector}`, and the caller saves each element as a PNG named `file`. It throws an `Error` with one line, and draws nothing, for a document without `kind` or a known `source`, a wrong pairing, a missing section, a bad `collected_at` or node name, or a host-check desired document alone. Both images of a pair take their column widths from the desired table, so they line up.

The images apply [their rules](../docs/report.md#read-the-images) on top of the comparison's differences, so an image can pass where the comparison finds a difference, such as a value only the desired document has.

## Build

On an x86_64 Linux host with network, docker, curl, unzip and sha256sum:

```bash
bash report/build.sh build/cnpg-report
```

It downloads the pinned Chrome zip and checks its SHA-256, gathers the RPMs' libraries and licence texts in a pinned UBI9 container, packs the payload, and builds the launcher in a pinned Go container with `CGO_ENABLED=0`. `launcher/payload.tar.gz` exists only during a build, so `go vet`, `go test` and `go build` in `launcher/` run only inside it.

## Tests

```bash
(cd report && node --test test/*.test.js)     # Node.js 20, bash, jq and openssl
bash report/test/binary.sh build/cnpg-report images
bash report/test/docker-example.sh VERSION OUT_DIR
```

- The unit tests also check that each `samples/*.desired.json` is what `desired.sh` prints; after a change to the scripts, write them again with it. CI runs them in the `page` job.
- `binary.sh` runs the binary in `ubi9-minimal` with no network on every sample, compares the files with [the image list](../docs/report.md#image-files) (`test/expected-images.sh`), checks exit 2 on broken input, and fails on any open of an OS library or font under `strace`. CI runs it in the `report` job.
- `docker-example.sh` runs the [container example](../docs/report.md#in-a-container) as written on `ghcr.io/djosh34/cnpg-report:VERSION`. CI runs it on a local image, the release on the pushed one.

To look at the images while changing the page, from `report/` with a local Chrome:

```bash
npm ci
node dev/render.js /path/to/chrome /tmp/report-images
```
