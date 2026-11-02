#!/bin/sh
# The first process of each node container that live/up.sh starts, in place
# of k3s itself. It runs "k3s server" with its arguments and starts it again
# 5 s after it exits, as k3s's systemd unit does (Restart=always,
# KillMode=process). So the node's pods keep running while k3s is down, as on
# a VM. k3s exits, for example, when it loses a leader lease because two of
# three nodes are gone; as the container's first process, its exit would stop
# every pod on the node.
#
# First it moves itself out of the container's root cgroup and enables the
# controllers for the cgroups below it, which k3s does itself only when it
# runs as the first process, so that containerd can create cgroups there.
#
# Runs in the k3s image, which has busybox sh.
set -eu

cgroup=/sys/fs/cgroup
if [ -f "$cgroup/cgroup.controllers" ]; then
  mkdir -p "$cgroup/init"
  echo $$ >"$cgroup/init/cgroup.procs"
  read -r controllers <"$cgroup/cgroup.controllers"
  for controller in $controllers; do
    echo "+$controller" >"$cgroup/cgroup.subtree_control"
  done
fi

while true; do
  status=0
  /bin/k3s server "$@" || status=$?
  echo "node-init.sh: k3s exited with code $status; starting it again in 5 s" >&2
  sleep 5
done
