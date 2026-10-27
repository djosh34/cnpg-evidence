#!/usr/bin/env bash
# Reads the first enable_selinux setting from containerd's configuration.
# Usage: containerd-selinux.sh [CONFIG_TOML]
# Exit: 0 with the setting or empty output when absent, nonzero on errors.
set -euo pipefail
shopt -s inherit_errexit

file=${1:-/var/lib/rancher/k3s/agent/etc/containerd/config.toml}
if [[ -f $file ]]; then
  sed -n 's/^[[:space:]]*enable_selinux[[:space:]]*=[[:space:]]*//p' "$file" | sed -n 1p
fi
