#!/usr/bin/env bash
# Runs the SQL on stdin as postgres in one instance pod and prints its one
# JSON line, compacted. The SQL itself opens a READ ONLY transaction.
#
# Usage: psql.sh NAMESPACE POD <file.sql
set -euo pipefail
shopt -s inherit_errexit

namespace=$1
pod=$2

kubectl exec -i -n "$namespace" "$pod" -c postgres -- \
  psql -XAtq -v ON_ERROR_STOP=1 -d postgres |
  jq -c .
