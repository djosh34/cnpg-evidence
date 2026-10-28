#!/usr/bin/env bash
# Runs the SQL on stdin as postgres in one instance pod and prints its one
# JSON line, compacted. The SQL itself opens a READ ONLY transaction.
#
# psql runs with an empty environment, so no PG* variable of the container
# changes what it connects to or how: the user, the database and CNPG's
# socket directory and port are given here.
#
# Usage: psql.sh NAMESPACE POD <file.sql
set -euo pipefail
shopt -s inherit_errexit

namespace=$1
pod=$2

kubectl exec -i -n "$namespace" "$pod" -c postgres -- \
  env -i psql -XAtq -v ON_ERROR_STOP=1 -h /controller/run -p 5432 -U postgres -d postgres |
  jq -c .
