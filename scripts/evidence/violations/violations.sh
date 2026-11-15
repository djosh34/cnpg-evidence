#!/usr/bin/env bash
# Every violation, as one list of {path, sentence}: the sentence starts with
# a rule number, and path names the evidence value it is about. The
# violations of each section, in order, or of the one section given.
#
# Usage: violations.sh [SECTION] <{facts, values, expected_ca, granted_by, operator_account, plugin_account}
#   SECTION: postgres, logins, client-ca, tls, kubernetes or pods.
#   granted_by: the reasons of the kubernetes section, see kubernetes/kubernetes.jq.
# Exit 0 with the list on stdout, not 0 when a section cannot read its facts.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

sections=(postgres logins client-ca tls kubernetes pods)
if (($# > 0)); then
  [[ $# -eq 1 && " ${sections[*]} " == *" $1 "* ]] || {
    echo "usage: violations.sh [SECTION] <input, SECTION one of: ${sections[*]}" >&2
    exit 2
  }
  sections=("$1")
fi

input=$(cat)

for section in "${sections[@]}"; do
  jq -c -L "$here" -f "$here/$section.jq" <<<"$input"
done | jq -s add
