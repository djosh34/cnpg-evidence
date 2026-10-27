#!/usr/bin/env bash
# Builds cnpg-report: one static x86_64 Linux file that carries
# chrome-headless-shell, the libraries it needs from UBI9 RPMs, glibc and its
# loader, the fonts, the page and their licence texts.
#
# Usage: bash report/build.sh OUT_FILE
# Needs an x86_64 Linux host with network, docker (or podman as docker), curl,
# unzip and sha256sum, such as a GitHub ubuntu-24.04 runner.
set -euo pipefail

chrome_version=156.0.8078.47
chrome_sha256=0d5acc62c3e213f8c87d3c298d66ffcf9a236d12ea4b9f85318bf85dbc279daa
ubi=registry.access.redhat.com/ubi9/ubi@sha256:48393e4261b2544f652c915b3e052256ddf66ee95cd04dc0362191f302c4e94a
golang=docker.io/library/golang:1.27-bookworm@sha256:972b4110ba0f47539a975c31e52c64765e1ff19f2d74469ae4a595c6676e80a5

if [ $# -ne 1 ]; then
  echo "usage: bash report/build.sh OUT_FILE" >&2
  exit 2
fi
out=$(realpath -m "$1")
report=$(cd "$(dirname "$0")" && pwd)
launcher=$report/launcher

work=$(mktemp -d)
# The containers run as root and leave files only root may remove.
trap 'docker run --rm -v "$work:/work" "$ubi" find /work -mindepth 1 -delete && rmdir "$work"' EXIT
payload=$work/payload
mkdir -p "$payload/licenses/chrome-for-testing" "$payload/licenses/fonts" "$payload/licenses/go" "$payload/fonts" "$payload/cache"

echo "Chrome for Testing $chrome_version" >&2
curl -fsSL -o "$work/chrome.zip" \
  "https://storage.googleapis.com/chrome-for-testing-public/$chrome_version/linux64/chrome-headless-shell-linux64.zip"
echo "$chrome_sha256  $work/chrome.zip" | sha256sum -c - >&2
unzip -q "$work/chrome.zip" -d "$work"
mv "$work/chrome-headless-shell-linux64" "$payload/chrome"
mv "$payload/chrome/LICENSE.headless_shell" "$payload/chrome/ABOUT" "$payload/licenses/chrome-for-testing/"

echo "Libraries from UBI9" >&2
docker run --rm -v "$payload:/payload" -v "$launcher/libs.sh:/libs.sh:ro" "$ubi" bash /libs.sh /payload

echo "Fonts and page" >&2
cp -r "$report/page" "$payload/page"
cp "$report"/page/fonts/*.ttf "$payload/fonts/"
cp "$report/page/fonts/OFL.txt" "$payload/licenses/fonts/"
cp "$launcher/fonts.conf" "$payload/fonts.conf"

echo "Launcher" >&2
docker run --rm -v "$payload:/payload" -v "$launcher:/launcher:ro" -v "$work:/work" -w /launcher \
  -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH=amd64 -e GOFLAGS=-trimpath "$golang" bash -euo pipefail -c '
    go version >&2
    cp "$(go env GOROOT)/LICENSE" /payload/licenses/go/LICENSE
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 -C /payload -cf - . | gzip -9n > /work/payload.tar.gz
    mkdir /work/src
    cp /launcher/*.go /launcher/go.mod /work/src/
    cp /work/payload.tar.gz /work/src/
    cd /work/src
    go vet ./...
    go build -ldflags=-s -o /work/cnpg-report .
  '
mkdir -p "$(dirname "$out")"
cp "$work/cnpg-report" "$out"
file "$out"
ls -l "$out"
