#!/usr/bin/env bash
# Checks k3s credential paths and the server's secrets-encryption setting.
# Usage: k3s-secrets.sh [KUBECONFIG [CONFIG_YAML [SERVER_DIR [UNIT...]]]]
# Exit: 0 with one JSON check, nonzero on collection errors.
set -euo pipefail
shopt -s inherit_errexit nullglob

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../lib.sh"

kubeconfig=${1:-/etc/rancher/k3s/k3s.yaml}
config=${2:-/etc/rancher/k3s/config.yaml}
server=${3:-/var/lib/rancher/k3s/server}
failures=()
details=()

check_path() {
  local path=$1 limit=$2 check
  if [[ ! -e $path ]]; then
    details+=("$path absent")
    return
  fi
  check=$(bash "$here/../mode/mode.sh" k3s-secrets "$path" "$limit")
  details+=("$(jq -r .raw <<<"$check")")
  if [[ $(jq -r .ok <<<"$check") == false ]]; then
    failures+=("$path: $(jq -r .value <<<"$check")")
  fi
}

check_path "$kubeconfig" 600
for file in "$config" "$config".d/*.yaml; do
  [[ -f $file ]] || continue
  # Only the setting name is read here; its value never leaves the file.
  token_setting=$(awk '/^[[:space:]]*["\047]?(token|agent-token)["\047]?[[:space:]]*:/ {print "present"; exit}' "$file")
  if [[ -n $token_setting ]]; then
    check_path "$file" 600
  else
    details+=("$file has no token setting")
  fi
done
if [[ ! -e $kubeconfig && ! -e $server ]]; then
  details+=("agent node: server directory and secrets-encryption not required")
else
  check_path "$server" 700
  settings=$(bash "$here/../k3s-config/k3s-config.sh" "$config" "${@:4}")
  lines=$(jq -r '[.[][] | select(test("secrets-encryption"))] | join("; ")' <<<"$settings")
  enabled=$(jq -r '[.[][] | select(test("secrets-encryption"))] | last // "" |
    test("^(secrets-encryption: true|--secrets-encryption(=true)?)$")' <<<"$settings")
  details+=("${lines:-secrets-encryption unset}")
  [[ $enabled == true ]] || failures+=("secrets-encryption off")
fi
ok=true value=none
if ((${#failures[@]})); then
  ok=false value=$(joined "${failures[@]}")
fi
add_check k3s-secrets "$ok" "$value" "$(joined "${details[@]}")"
