#!/usr/bin/env bash
# Collects host versions, configuration, listeners and subordinate-id entries.
# Usage: collected.sh UID GID
# Exit: 0 with one JSON object, nonzero on collection errors.
set -euo pipefail
shopt -s inherit_errexit nullglob

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

subids_json() {
  if [[ -f $1 ]]; then
    sed -E '/^[[:space:]]*(#|$)/d' "$1" | jq -Rn '[inputs]'
  else
    echo null
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
selinux=$(bash "$here/../selinux-enforcing/selinux-enforcing.sh" mode)
containerd_selinux=$(bash "$here/../containerd-selinux/containerd-selinux.sh")
getsubids=$(command -v getsubids || true)

k3s_config=$(bash "$here/../k3s-config/k3s-config.sh")
listening_tcp=$(bash "$here/../listening-tcp/listening-tcp.sh")
firewalld=$(bash "$here/../firewalld/firewalld.sh")
subuid=$(subids_json /etc/subuid)
subgid=$(subids_json /etc/subgid)
missing_tools=$(
  for tool in ss rpm getent firewall-cmd k3s getcap; do
    have "$tool" || echo "$tool"
  done | jq -Rn '[inputs]'
)

jq -n --arg hostname "$hostname" --arg os "$os" --arg kernel "$kernel" \
  --arg k3s "$k3s" --arg containerd "$containerd" --arg selinux "$selinux" \
  --arg containerd_selinux "$containerd_selinux" \
  --arg postgres_uid "$1" --arg postgres_gid "$2" --arg getsubids "$getsubids" \
  --slurpfile k3s_config <(printf '%s\n' "$k3s_config") \
  --slurpfile listening_tcp <(printf '%s\n' "$listening_tcp") \
  --slurpfile firewalld <(printf '%s\n' "$firewalld") \
  --slurpfile subuid <(printf '%s\n' "$subuid") \
  --slurpfile subgid <(printf '%s\n' "$subgid") \
  --slurpfile missing_tools <(printf '%s\n' "$missing_tools") \
  -f "$here/collected.jq"
