#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

kubectl() {
  case "$*" in
    "version -o json")
      echo '{"serverVersion": {"gitVersion": "v1.2.3+k3s1"}}' ;;
    "get deployments -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg -o json")
      echo '{"items": [{"spec": {"template": {"spec": {"containers": [{"image": "ghcr.io/cloudnative-pg/cloudnative-pg:1.2.3"}]}}}}]}' ;;
    "get deployments -n cnpg-system -l app.kubernetes.io/name=plugin-barman-cloud -o json")
      echo '{"items": [{"spec": {"template": {"spec": {"containers": [{"image": "example.com:5000/plugin-barman-cloud:v0.4.5@sha256:abc"}]}}}}]}' ;;
    "exec -i -n databases pg-1 -c postgres -- "*)
      echo '{"postgresql": "17.1"}' ;;
    *) return 1 ;;
  esac
}
export -f kubectl

expected=$(cat <<'EOF'
{"kubernetes": "v1.2.3+k3s1", "cnpg_operator": "1.2.3", "barman_cloud_plugin": "v0.4.5", "postgresql": "17.1"}
EOF
)
same "image tags without registry port or digest" "$expected" "$(bash "$here/software.sh" databases cnpg-system pg-1)"

finish
