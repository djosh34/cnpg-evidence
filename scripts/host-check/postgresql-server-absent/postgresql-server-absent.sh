#!/usr/bin/env bash
# Checks for installed PostgreSQL server packages.
# Usage: postgresql-server-absent.sh
# Exit: 0 with one JSON check (including a failed check), nonzero on errors.
set -euo pipefail
shopt -s inherit_errexit nullglob

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"

id=postgresql-server-absent
if ! have rpm; then
  add_check "$id" false "rpm not found" "rpm not found"
  exit 0
fi
pkgs=$(rpm -qa 'postgresql*-server' | sort)
if [[ -z $pkgs ]]; then
  add_check "$id" true none "no postgresql*-server package installed"
else
  add_check "$id" false "${pkgs//$'\n'/; }" "installed: ${pkgs//$'\n'/; }"
fi
