#!/usr/bin/env bash
# Tests credential modes, token-file selection, encryption and agent nodes.
# Usage: bash k3s-secrets.test.sh
# Exit: 0 when all assertions pass, nonzero on a failure.
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")

# shellcheck source-path=SCRIPTDIR
source "$here/../../lib/test.sh"

fixture=$(mktemp -d "$here/.test.XXXXXX")
trap 'rm -r "$fixture"' EXIT
mkdir "$fixture/server" "$fixture/config.yaml.d"
printf 'credentials\n' >"$fixture/k3s.yaml"
printf 'token: do-not-print\nsecrets-encryption: true\n' >"$fixture/config.yaml"
printf '"agent-token": also-do-not-print\n' >"$fixture/config.yaml.d/10-token.yaml"
printf 'node-name: do-not-print-either\n' >"$fixture/config.yaml.d/20-node.yaml"
stat() {
  if [[ ${*: -1} == */server ]]; then
    echo '700 root:root'
  elif [[ ${*: -1} == */20-node.yaml ]]; then
    echo '644 root:root'
  else
    echo '600 root:root'
  fi
}
ls() { echo '-rw------- 1 root root'; }
export -f stat ls
run() { bash "$here/k3s-secrets.sh" "$fixture/k3s.yaml" "$fixture/config.yaml" "$fixture/server" "$fixture/unit"; }
actual=$(run)
same "tight credentials and encryption pass" '{"id":"k3s-secrets","ok":true,"value":"none"}' "$(jq '{id,ok,value}' <<<"$actual")"
same "no secret or unrelated value printed" false "$(jq 'tostring | contains("do-not-print")' <<<"$actual")"
stat() {
  if [[ ${*: -1} == */k3s.yaml ]]; then echo '644 root:root'; else echo '600 root:root'; fi
}
export -f stat
same_text "kubeconfig mode fails" "$fixture/k3s.yaml: 644, root:root, no ACL" "$(run | jq -r .value)"
stat() {
  case ${*: -1} in
    */server) echo '750 root:root' ;;
    */10-token.yaml) echo '644 root:root' ;;
    *) echo '600 root:root' ;;
  esac
}
export -f stat
same_text "token drop-in and server modes fail" "$fixture/config.yaml.d/10-token.yaml: 644, root:root, no ACL; $fixture/server: 750, root:root, no ACL" "$(run | jq -r .value)"
stat() { echo '600 root:root'; }
export -f stat
printf 'secrets-encryption: false\n' >"$fixture/config.yaml.d/30-encryption.yaml"
same_text "later config disables encryption" 'secrets-encryption off' "$(run | jq -r .value)"
printf "ExecStart=/usr/local/bin/k3s server '--secrets-encryption' '--token=do-not-print'\n" >"$fixture/unit"
same_text "unit enables encryption" none "$(run | jq -r .value)"
printf "ExecStart=/usr/local/bin/k3s server '--secrets-encryption=false'\n" >"$fixture/unit"
same_text "unit disables encryption" 'secrets-encryption off' "$(run | jq -r .value)"
rm "$fixture/unit" "$fixture/config.yaml.d/30-encryption.yaml"
printf 'token: do-not-print\n' >"$fixture/config.yaml"
same_text "unset encryption fails on server" 'secrets-encryption off' "$(run | jq -r .value)"
rm "$fixture/k3s.yaml"
rmdir "$fixture/server"
actual=$(run)
same "agent skips server requirements" '{"ok":true,"value":"none"}' "$(jq '{ok,value}' <<<"$actual")"
same "agent explanation" true "$(jq '.raw | contains("agent node: server directory and secrets-encryption not required")' <<<"$actual")"
stat() { echo '644 root:root'; }
export -f stat
same_text "agent token files still checked" "$fixture/config.yaml: 644, root:root, no ACL; $fixture/config.yaml.d/10-token.yaml: 644, root:root, no ACL" "$(run | jq -r .value)"
same_text "all absent passes" none "$(bash "$here/k3s-secrets.sh" "$fixture/absent" "$fixture/absent-config" "$fixture/absent-server" | jq -r .value)"

finish
