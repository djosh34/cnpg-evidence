#!/usr/bin/env bash
# Raises the host's fs.inotify.max_user_instances to 1024, which the bench
# needs: each of its three k3s nodes takes many inotify instances, the limit
# is the host's for every container, and many hosts have 128. The bench
# checks the limit at start and never changes it itself.
#
# The value holds until the next reboot. To keep it, put
# "fs.inotify.max_user_instances = 1024" into a file in /etc/sysctl.d/.
#
# Usage: bash bench/host.sh
set -euo pipefail

want=1024
have=$(sysctl -n fs.inotify.max_user_instances)
if ((have >= want)); then
  echo "fs.inotify.max_user_instances is $have, at least $want"
  exit 0
fi
sudo sysctl -w "fs.inotify.max_user_instances=$want"
