#!/usr/bin/env bash
# Collects SELinux and network-policy settings from k3s files and unit flags.
# Usage: k3s-config.sh [CONFIG_YAML [SYSTEMD_UNIT...]]
# Exit: 0 with a JSON object (empty for missing files), nonzero on errors.
set -euo pipefail
shopt -s inherit_errexit nullglob

config=${1:-/etc/rancher/k3s/config.yaml}
units=("${@:2}")
((${#units[@]})) || units=(/etc/systemd/system/k3s.service /etc/systemd/system/k3s-agent.service)
keys='selinux|disable-network-policy'

{
  for file in "$config" "$config".d/*.yaml; do
    [[ -f $file ]] || continue
    sed -nE "s/^[[:space:]]*($keys)[[:space:]]*:[[:space:]]*([^#[:space:]]*).*/\1: \2/p" "$file" |
      jq -Rn --arg f "$file" '{($f): [inputs]}'
  done
  for unit in "${units[@]}"; do
    [[ -f $unit ]] || continue
    awk '/^ExecStart=/ {on = 1} on && NF {print} on && !/\\$/ {exit}' "$unit" |
      { grep -oE -- "--($keys)(=[^[:space:]'\"\\]*)?" || true; } |
      jq -Rn --arg f "$unit" '{($f): [inputs]}'
  done
} | jq -s 'add // {}'
