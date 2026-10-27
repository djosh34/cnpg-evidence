#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

here=$(dirname "${BASH_SOURCE[0]}")
source "$here/../../lib/test.sh"

input=$(cat <<'EOF'
[
  {"metadata": {"namespace": "otel", "name": "root-default"},
   "spec": {"hostNetwork": true, "containers": [{"name": "c"}]}},
  {"metadata": {"namespace": "otel", "name": "drops-all"},
   "spec": {"hostNetwork": true, "containers": [{"name": "c", "securityContext": {"capabilities": {"drop": ["ALL"]}}}]}},
  {"metadata": {"namespace": "otel", "name": "drops-bind"},
   "spec": {"hostNetwork": true, "containers": [{"name": "c", "securityContext": {"capabilities": {"drop": ["cap_net_bind_service"]}}}]}},
  {"metadata": {"namespace": "otel", "name": "drops-all-adds-bind"},
   "spec": {"hostNetwork": true, "containers": [{"name": "c", "securityContext": {"capabilities": {"drop": ["ALL"], "add": ["NET_BIND_SERVICE"]}}}]}},
  {"metadata": {"namespace": "otel", "name": "adds-all-drops-all"},
   "spec": {"hostNetwork": true, "containers": [{"name": "c", "securityContext": {"capabilities": {"drop": ["ALL"], "add": ["ALL"]}}}]}},
  {"metadata": {"namespace": "otel", "name": "adds-and-drops-bind"},
   "spec": {"hostNetwork": true, "containers": [{"name": "c", "securityContext": {"capabilities": {"drop": ["NET_BIND_SERVICE"], "add": ["NET_BIND_SERVICE"]}}}]}},
  {"metadata": {"namespace": "otel", "name": "non-root-pod"},
   "spec": {"hostNetwork": true, "securityContext": {"runAsUser": 10001},
            "containers": [{"name": "c", "securityContext": {"allowPrivilegeEscalation": false}}]}},
  {"metadata": {"namespace": "otel", "name": "non-root-flag"},
   "spec": {"hostNetwork": true, "securityContext": {"runAsNonRoot": true},
            "containers": [{"name": "c", "securityContext": {"allowPrivilegeEscalation": false}}]}},
  {"metadata": {"namespace": "otel", "name": "non-root-can-escalate"},
   "spec": {"hostNetwork": true, "securityContext": {"runAsUser": 10001}, "containers": [{"name": "c"}]}},
  {"metadata": {"namespace": "otel", "name": "non-root-adds-bind"},
   "spec": {"hostNetwork": true, "securityContext": {"runAsUser": 10001},
            "containers": [{"name": "c", "securityContext": {"allowPrivilegeEscalation": false,
                                                             "capabilities": {"drop": ["ALL"], "add": ["NET_BIND_SERVICE"]}}}]}},
  {"metadata": {"namespace": "otel", "name": "container-overrides-pod"},
   "spec": {"hostNetwork": true, "securityContext": {"runAsNonRoot": true},
            "containers": [{"name": "c", "securityContext": {"runAsNonRoot": false, "allowPrivilegeEscalation": false}}]}},
  {"metadata": {"namespace": "otel", "name": "root-in-init"},
   "spec": {"hostNetwork": true, "securityContext": {"runAsUser": 10001},
            "initContainers": [{"name": "i", "securityContext": {"runAsUser": 0, "allowPrivilegeEscalation": false}}],
            "containers": [{"name": "c", "securityContext": {"allowPrivilegeEscalation": false}}]}},
  {"metadata": {"namespace": "otel", "name": "privileged"},
   "spec": {"hostNetwork": true,
            "containers": [{"name": "c", "securityContext": {"privileged": true, "capabilities": {"drop": ["ALL"]}}}]}},
  {"metadata": {"namespace": "otel", "name": "pod-network"},
   "spec": {"containers": [{"name": "c"}]}},
  {"metadata": {"namespace": "kube-system", "name": "root-in-kube-system"},
   "spec": {"hostNetwork": true, "containers": [{"name": "c"}]}}
]
EOF
)

expected=$(cat <<'EOF'
["kube-system/root-in-kube-system", "otel/container-overrides-pod", "otel/drops-all-adds-bind",
 "otel/non-root-can-escalate", "otel/privileged", "otel/root-default", "otel/root-in-init"]
EOF
)
same "hostNetwork pods that keep NET_BIND_SERVICE and run as root or can escalate" \
  "$expected" "$(jq -f "$here/host-network.jq" <<<"$input")"

finish
