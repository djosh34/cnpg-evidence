#!/usr/bin/env bash
# Changes to the socket directory, then connects as postgres through host=/proc/self/cwd.
# Usage: socket.sh DIRECTORY
# Exit: 0 login succeeded, 2 traversal or login failed.
set -euo pipefail
shopt -s inherit_errexit

# Change directory as the uid running this shell.
cd -- "$1" || exit 2
psql -w -X -At -c 'select current_user' 'host=/proc/self/cwd dbname=postgres user=postgres' || exit 2
