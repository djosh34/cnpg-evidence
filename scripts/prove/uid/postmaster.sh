#!/usr/bin/env bash
# Prints the pid of a postgres process whose cgroup contains the pod object id.
# Usage: postmaster.sh POD_UID
# Exit: 0 with the pid, 2 no matching process or lookup error.
set -euo pipefail
shopt -s inherit_errexit

pattern=${1//-/[-_]}
pids=$(pgrep -f '^postgres -D') || exit 2
for pid in $pids; do
  if grep -Eq "pod$pattern" "/proc/$pid/cgroup" 2>/dev/null; then
    echo "$pid"
    exit 0
  fi
done
exit 2
