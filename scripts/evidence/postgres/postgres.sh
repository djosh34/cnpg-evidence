#!/usr/bin/env bash
# The postgres section: which roles can do what, read on the primary.
#
# Usage: postgres.sh NAMESPACE PRIMARY_POD
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

bash "$here/../psql/psql.sh" "$1" "$2" <"$here/postgres.sql"
