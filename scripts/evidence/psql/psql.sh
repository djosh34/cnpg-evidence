#!/usr/bin/env bash
# Runs the SQL on stdin as postgres in one instance pod and prints its one
# JSON line, compacted. The SQL itself opens a READ ONLY transaction.
#
# The exec runs only psql, the one program of the instance image the scripts
# use. The user, the database and CNPG's socket directory and port are given
# here, so no PG* variable of the container changes what it connects to, and
# -X skips any psqlrc.
#
# Usage: psql.sh NAMESPACE POD <file.sql
set -euo pipefail
shopt -s inherit_errexit

namespace=$1
pod=$2

kubectl exec -i -n "$namespace" "$pod" -c postgres -- \
  psql -XAtq -v ON_ERROR_STOP=1 -h /controller/run -p 5432 -U postgres -d postgres |
  jq -c .
