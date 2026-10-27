#!/usr/bin/env bash
# Runs inside UBI9, called by report/build.sh. Installs the RPMs that hold the
# libraries Chrome needs and copies those libraries, glibc and its loader, and
# the RPMs' licence texts into the payload.
#
# Usage: bash libs.sh PAYLOAD_DIR
# Reads PAYLOAD_DIR/chrome; writes PAYLOAD_DIR/lib, PAYLOAD_DIR/chrome/<loader>,
# PAYLOAD_DIR/licenses/rpm/<RPM>/ and PAYLOAD_DIR/licenses/rpms.txt.
set -euo pipefail
# A failure inside $(...) stops the script too, as in upstream_tarball.
shopt -s inherit_errexit

payload=$1
loader=/lib64/ld-linux-x86-64.so.2

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

# upstream_tarball RPM DIR: unpacks RPM's source RPM from UBI9 into DIR and
# prints the path of its upstream tarball, or nothing if it has none.
upstream_tarball() {
  local rpm=$1 dir=$2 srpm
  srpm=$(rpm -q --qf '%{SOURCERPM}' "$rpm")
  (cd "$dir" && "${dnf[@]}" download -q --source --enablerepo='ubi-9-*-source-rpms' "$rpm" >&2 &&
    rpm2cpio "$srpm" | cpio -idm --quiet)
  find "$dir" -maxdepth 1 -name "${srpm%-*-*}-$(rpm -q --qf '%{VERSION}' "$rpm").tar.*"
}

# source_texts RPM DEST: copies the licence files at the top of the upstream
# tarball in RPM's source RPM, or in its docs/ directory, into DEST.
source_texts() {
  local rpm=$1 dest=$2 tarball dir
  dir=$(mktemp -d)
  tarball=$(upstream_tarball "$rpm" "$dir")
  if [ -n "$tarball" ]; then
    mapfile -t members < <(tar -tf "$tarball" |
      grep -iE '^[^/]+/(docs/)?(copying|licen[cs]e|copyright)[^/]*$' || [ $? = 1 ])
    if [ "${#members[@]}" -gt 0 ]; then
      mkdir -p "$dest" "$dir/x"
      tar -xf "$tarball" -C "$dir/x" "${members[@]}"
      for member in "${members[@]}"; do
        cp "$dir/x/$member" "$dest/"
      done
    fi
  fi
  rm -rf "$dir"
}

# libdrm_notice DEST: libdrm has no licence file in its RPM or its upstream
# source; its MIT notice is in the comments of its sources. Writes the notice
# comment of each file libdrm.so.2 is built from, the xf86drm*.c files at the
# top of the upstream tarball, into DEST/NOTICE.
libdrm_notice() {
  local dest=$1 tarball dir file
  dir=$(mktemp -d)
  tarball=$(upstream_tarball libdrm "$dir")
  mkdir -p "$dir/x" "$dest"
  tar -xf "$tarball" -C "$dir/x" --wildcards --no-wildcards-match-slash '*/xf86drm*.c'
  for file in "$dir"/x/*/xf86drm*.c; do
    echo "${file#"$dir/x/"}:"
    awk '/^\/\*/ { block = ""; open = 1 }
      open { block = block $0 "\n" }
      open && /\*\// { open = 0; if (block ~ /Permission is hereby granted/) { printf "%s\n", block; found = 1; exit } }
      END { if (!found) exit 1 }' "$file"
  done > "$dest/NOTICE"
  rm -rf "$dir"
}

# Each RPM's texts go into licenses/rpm/<RPM>/. Some RPMs keep them in a
# sibling RPM of the same source RPM, such as libX11 in libX11-common, so the
# siblings' texts count too. An RPM with no text gets those of its upstream
# source, from the UBI9 source RPM, and libdrm the notice in its sources.
# licenses/rpms.txt names the licence and the project URL of every RPM, and
# the RPMs that still have no text: their source has no licence file either.
"${dnf[@]}" install cpio bzip2 xz >&2
no_text=()
for rpm in "${rpms[@]}"; do
  source=$(rpm -q --qf '%{SOURCERPM}' "$rpm")
  mapfile -t siblings < <(rpm -qa --qf '%{NAME} %{SOURCERPM}\n' | awk -v s="$source" '$2 == s { print $1 }')
  for text in $(licence_texts "${siblings[@]}" | sed '/^(contains no files)$/d' | sort -u); do
    dest=$payload/licenses/rpm/$rpm/$(basename "$(dirname "$text")")/$(basename "$text")
    mkdir -p "$(dirname "$dest")"
    cp -L "$text" "$dest"
  done
  if [ ! -d "$payload/licenses/rpm/$rpm" ]; then
    source_texts "$rpm" "$payload/licenses/rpm/$rpm/source"
  fi
  if [ "$rpm" = libdrm ] && [ ! -d "$payload/licenses/rpm/$rpm" ]; then
    libdrm_notice "$payload/licenses/rpm/$rpm/source"
  fi
  if [ ! -d "$payload/licenses/rpm/$rpm" ]; then
    no_text+=("$rpm")
  fi
done
{
  rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\t%{LICENSE}\t%{URL}\n' "${rpms[@]}"
  if [ "${#no_text[@]}" -gt 0 ]; then
    echo
    echo "No licence file in the RPM or its upstream source: ${no_text[*]}"
  fi
} > "$payload/licenses/rpms.txt"
