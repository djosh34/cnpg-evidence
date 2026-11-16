#!/bin/sh
# Runs a command that downloads from outside, up to 5 times, with a longer
# pause after each failure: a package mirror or a download host can answer
# an error for a moment, and one failed download fails the whole job.
# Each failed try names the command, so the log shows the host. The RUN
# steps of e2e/Dockerfile use it; it is plain sh for the Alpine stages.
#
# Usage: retry <command> [<argument>...]
set -u

try=1
while :; do
  "$@" && exit 0
  if [ "$try" -ge 5 ]; then
    echo "retry: failed 5 times: $*" >&2
    exit 1
  fi
  echo "retry: try $try failed, again in $((try * 10)) s: $*" >&2
  sleep $((try * 10))
  try=$((try + 1))
done
