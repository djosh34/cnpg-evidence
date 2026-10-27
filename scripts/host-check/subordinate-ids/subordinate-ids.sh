#!/usr/bin/env bash
# Checks subordinate-id files for overlap with kubelet's pod host-id range.
# Usage: subordinate-ids.sh [SUBUID_FILE [SUBGID_FILE]]
# Exit: 0 with one JSON check (including malformed/overlapping entries),
#   nonzero on command errors.
set -euo pipefail
shopt -s inherit_errexit nullglob

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"

# kubelet's entry in FILE, or nothing without the kubelet account, getsubids or
# the file.
kubelet_entry() {
  local file=$1
  if have getsubids && have getent && getent passwd kubelet >/dev/null && [[ -f $file ]]; then
    awk -F: '$1 == "kubelet" {print; exit}' "$file"
  fi
}

subuid=${1:-/etc/subuid}
subgid=${2:-/etc/subgid}
hits=()
ranges=()
for file in "$subuid" "$subgid"; do
  entry=$(kubelet_entry "$file")
  if [[ -z $entry ]]; then
    start=65536 count=4294901760
  elif [[ $entry =~ ^kubelet:([0-9]{1,10}):([0-9]{1,10})$ ]] &&
    ((10#${BASH_REMATCH[2]} > 0 && 10#${BASH_REMATCH[1]} + 10#${BASH_REMATCH[2]} <= 4294967296)); then
    start=$((10#${BASH_REMATCH[1]})) count=$((10#${BASH_REMATCH[2]}))
  else
    # A malformed, empty or out-of-range kubelet entry fails, and nothing can be
    # checked against it.
    hits+=("$file: $entry")
    ranges+=("$file none")
    continue
  fi
  ranges+=("$file $start-$((start + count - 1))")
  [[ -f $file ]] || continue
  overlapping=$(awk -F: -v s="$start" -v e="$((start + count))" '
    /^[[:space:]]*(#|$)/ {next}
    NF != 3 || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ {print FILENAME ": " $0; next}
    $1 == "kubelet" {next}
    $2 < e && $2 + $3 > s {print FILENAME ": " $0}
  ' "$file")
  if [[ -n $overlapping ]]; then
    mapfile -t -O "${#hits[@]}" hits <<<"$overlapping"
  fi
done
if ((${#hits[@]})); then
  add_check subordinate-ids false "$(joined "${hits[@]}")" \
    "malformed or overlapping entries, kubelet range ($(joined "${ranges[@]}")): $(joined "${hits[@]}")"
else
  add_check subordinate-ids true none "no entry other than kubelet overlaps kubelet range ($(joined "${ranges[@]}"))"
fi
