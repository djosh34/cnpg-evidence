#!/usr/bin/env bash
# Tests first-setting selection and missing containerd configuration.
# Usage: bash containerd-selinux.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

sed() {
  if (($# == 3)); then
    builtin command sed "$1" "$2" <<'TOML'
[plugins.linux]
  enable_selinux = true
  enable_selinux = false
TOML
  else
    builtin command sed "$@"
  fi
}
export -f sed
same_text "first effective setting" true "$(bash "$here/containerd-selinux.sh" "$here/containerd-selinux.test.sh")"
same_text "missing config" '' "$(bash "$here/containerd-selinux.sh" /no-such-containerd-config)"

finish
