#!/usr/bin/env bash
# Every violation, as one list of {path, sentence}: the sentence starts with
# a rule number, and path names the evidence value it is about. The
# violations of each section, in order.
#
# Usage: violations.sh <{facts, values, expected_ca, granted_by, operator_account, plugin_account}
#   granted_by: the reasons of the kubernetes section, see kubernetes/kubernetes.jq.
# Exit 0 with the list on stdout, not 0 when a section cannot read its facts.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

input=$(cat)

for section in postgres logins client-ca tls kubernetes pods; do
  jq -c -L "$here" -f "$here/$section.jq" <<<"$input"
done | jq -s add
