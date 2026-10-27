#!/usr/bin/env python3
# Keeps libpq's regular private key file anonymous and memory-backed.
# Usage: key.py COMMAND [ARG...] < private-key
# Exit: command status after exec, nonzero on key setup failure.
import os
import sys

key_fd = os.memfd_create("prove-replication-key", flags=0)
os.fchmod(key_fd, 0o600)
with os.fdopen(os.dup(key_fd), "wb") as key:
    key.write(sys.stdin.buffer.read())
os.environ["PGSSLKEY"] = f"/proc/self/fd/{key_fd}"
os.execvp(sys.argv[1], sys.argv[1:])
