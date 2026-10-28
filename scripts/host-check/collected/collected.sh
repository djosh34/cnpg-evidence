#!/usr/bin/env bash
# Collects host versions, SELinux settings, identities and TCP listeners.
# Usage: collected.sh UID GID
# Exit: 0 with one JSON object, nonzero on collection errors.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"

containerd_version() {
  local bin=/var/lib/rancher/k3s/data/current/bin/containerd
  if [[ -x $bin ]]; then
    "$bin" --version
  elif have containerd; then
    containerd --version
  fi
}

hostname=$(< /proc/sys/kernel/hostname)
os=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')
kernel=$(uname -r)
k3s=
if have k3s; then
  k3s=$(k3s --version | sed -n 1p)
fi
containerd=$(containerd_version | sed -n 1p)
selinux=$(bash "$here/../selinux/selinux.sh" mode)
containerd_selinux=$(bash "$here/../containerd-selinux/containerd-selinux.sh")
listening_tcp=$(bash "$here/../listening-tcp/listening-tcp.sh")
missing_tools=$(
  for tool in ss rpm getent k3s getcap; do
    have "$tool" || echo "$tool"
  done | jq -Rn '[inputs]'
)

jq -n --arg hostname "$hostname" --arg os "$os" --arg kernel "$kernel" \
  --arg k3s "$k3s" --arg containerd "$containerd" --arg selinux "$selinux" \
  --arg containerd_selinux "$containerd_selinux" \
  --arg postgres_uid "$1" --arg postgres_gid "$2" \
  --slurpfile listening_tcp <(printf '%s\n' "$listening_tcp") \
  --slurpfile missing_tools <(printf '%s\n' "$missing_tools") \
  -f "$here/collected.jq"
