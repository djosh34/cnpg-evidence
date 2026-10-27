#!/usr/bin/env bash
# Prints the literal differences between a desired and an actual document of
# the same source as one JSON list; see compare.jq for the rule. A difference
# is not a failed check: the actual document's status stays the verdict.
#
# Usage: compare.sh DESIRED.json ACTUAL.json
# Exit 0 with the list, also when it is not empty; 2 on any error, with
# nothing on stdout.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../lib/common.sh"

(($# == 2)) || {
  echo "usage: ${0##*/} DESIRED.json ACTUAL.json" >&2
  exit 2
}
have jq || die "jq not found"

differences=$(jq -n --slurpfile desired "$1" --slurpfile actual "$2" -f "$here/compare.jq") ||
  die "cannot compare $1 with $2"
echo "$differences"
