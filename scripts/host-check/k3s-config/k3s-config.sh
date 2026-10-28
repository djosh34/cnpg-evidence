#!/usr/bin/env bash
# Collects SELinux, network-policy and encryption settings from k3s files and units.
# Usage: k3s-config.sh [CONFIG_YAML [SYSTEMD_UNIT...]]
# Exit: 0 with a JSON object (empty for missing files), nonzero on errors.
set -euo pipefail
shopt -s inherit_errexit nullglob

config=${1:-/etc/rancher/k3s/config.yaml}
units=("${@:2}")
((${#units[@]})) || units=(/etc/systemd/system/k3s.service /etc/systemd/system/k3s-agent.service)
keys='selinux|disable-network-policy|secrets-encryption'

{
  for file in "$config" "$config".d/*.yaml; do
    [[ -f $file ]] || continue
    sed -nE "s/^[[:space:]]*[\"']?($keys)[\"']?[[:space:]]*:[[:space:]]*[\"']?([^#[:space:]\"']*).*/\1: \2/p" "$file" |
      jq -Rn --arg f "$file" '{($f): [inputs]}'
  done
  for unit in "${units[@]}"; do
    [[ -f $unit ]] || continue
    awk '/^ExecStart=/ {on = 1} on && NF {print} on && !/\\$/ {exit}' "$unit" |
      { grep -oE -- "--($keys)(=[^[:space:]'\"\\]*)?" || { status=$?; [[ $status == 1 ]] || exit "$status"; }; } |
      jq -Rn --arg f "$unit" '{($f): [inputs]}'
  done
} | jq -s 'add // {}'
