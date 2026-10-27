#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

kubectl() {
  case "$*" in
    "get cluster pg -n databases -o jsonpath={.status.currentPrimary}")
      echo -n pg-1 ;;
    "get pods -n databases -l cnpg.io/cluster=pg,cnpg.io/podRole=instance -o json")
      cat <<'EOF' ;;
{"items": [
  {"metadata": {"name": "pg-2"}, "spec": {}},
  {"metadata": {"name": "pg-1"}, "spec": {"hostUsers": false}},
  {"metadata": {"name": "pg-3"}, "spec": {"hostUsers": true}}
]}
EOF
    *) return 1 ;;
  esac
}
export -f kubectl

expected=$(cat <<'EOF'
{"primary": "pg-1", "instances": ["pg-1", "pg-2", "pg-3"], "sharing_host_uids": ["pg-2", "pg-3"]}
EOF
)
same "hostUsers unset or true shares host uids" "$expected" "$(bash "$here/pods.sh" databases pg)"

finish
