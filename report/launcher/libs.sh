#!/usr/bin/env bash
# Runs inside UBI9, called by report/build.sh. Installs the RPMs that hold the
# libraries Chrome needs and copies those libraries, glibc and its loader, and
# the RPMs' licence texts into the payload.
#
# Usage: bash libs.sh PAYLOAD_DIR
# Reads PAYLOAD_DIR/chrome; writes PAYLOAD_DIR/lib, PAYLOAD_DIR/chrome/<loader>,
# PAYLOAD_DIR/licenses/rpm/<RPM>/ and PAYLOAD_DIR/licenses/rpms.txt.
set -euo pipefail

payload=$1
loader=${LOADER:-/lib64/ld-linux-x86-64.so.2}

# The RPMs of the libraries chrome-headless-shell links, and of those it
# opens at run time. NSS opens softokn and freebl; Chrome's GPU and video
# code opens libpci, libva, libva-drm, libwayland-client and libxcb-shm. A run-time
# library missing here would be looked for in the OS library paths.
packages=(
  glibc libgcc glib2 nspr nss nss-util nss-softokn nss-softokn-freebl
  atk at-spi2-atk at-spi2-core dbus-libs expat systemd-libs alsa-lib
  libX11 libXcomposite libXdamage libXext libXfixes libXrandr libxcb
  libxkbcommon mesa-libgbm pciutils-libs libva libwayland-client
)
opened=(
  libsoftokn3.so libfreeblpriv3.so libfreebl3.so
  libpci.so.3 libva.so.2 libva-drm.so.2 libwayland-client.so.0 libxcb-shm.so.0
)

# Docs are on, since some RPMs ship their licence text as a doc file.
dnf=(dnf -y --setopt=install_weak_deps=False --setopt=tsflags=)
"${dnf[@]}" install "${packages[@]}" >&2

mkdir -p "$payload/lib" "$payload/licenses/rpm"

# Every library Chrome loads, as ldd resolves them, except Chrome's own.
files=("$payload"/chrome/chrome-headless-shell "$payload"/chrome/*.so*)
for name in "${opened[@]}"; do
  files+=("/usr/lib64/$name")
done
ldd "${files[@]}" > "$payload/ldd.txt"
if grep -q 'not found' "$payload/ldd.txt"; then
  grep 'not found' "$payload/ldd.txt" >&2
  echo "libs.sh: a library Chrome needs is in no installed RPM" >&2
  exit 1
fi
libs=$(awk '$2 == "=>" && $3 ~ /^\// { print $3 }' "$payload/ldd.txt" | sort -u)
rm "$payload/ldd.txt"
for name in "${opened[@]}"; do
  libs+=$'\n'"/usr/lib64/$name"
done

rpms=()
for lib in $libs; do
  case $lib in "$payload"/chrome/*) continue ;; esac
  cp -L "$lib" "$payload/lib/$(basename "$lib")"
  rpms+=("$(rpm -qf --qf '%{NAME}\n' "$lib")")
done
cp -L "$loader" "$payload/chrome/$(basename "$loader")"
rpms+=("$(rpm -qf --qf '%{NAME}\n' "$loader")")

# Reinstall every RPM in use, as the base image strips the docs and licence
# texts of the RPMs it ships with.
mapfile -t rpms < <(printf '%s\n' "${rpms[@]}" | sort -u)
"${dnf[@]}" reinstall "${rpms[@]}" >&2

# The licence texts of RPMs: their licence files, and their doc files named
# like a licence.
licence_texts() {
  rpm -qL "$@"
  rpm -qd "$@" | awk 'tolower($0) ~ /\/(copying|licen[cs]e|copyright)[^\/]*$/'
}

# Each RPM's texts go into licenses/rpm/<RPM>/. Some RPMs keep them in a
# sibling RPM of the same source RPM, such as libX11 in libX11-common, so the
# siblings' texts count too. A few RPMs carry no text; licenses/rpms.txt names
# the licence and the project URL of every RPM.
for rpm in "${rpms[@]}"; do
  source=$(rpm -q --qf '%{SOURCERPM}' "$rpm")
  mapfile -t siblings < <(rpm -qa --qf '%{NAME} %{SOURCERPM}\n' | awk -v s="$source" '$2 == s { print $1 }')
  for text in $(licence_texts "${siblings[@]}" | sed '/^(contains no files)$/d' | sort -u); do
    dest=$payload/licenses/rpm/$rpm/$(basename "$(dirname "$text")")/$(basename "$text")
    mkdir -p "$(dirname "$dest")"
    cp -L "$text" "$dest"
  done
done
rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\t%{LICENSE}\t%{URL}\n' "${rpms[@]}" > "$payload/licenses/rpms.txt"
