# Pods that share their node's network and have a container that can bind a
# port below 1024 on the node: it keeps NET_BIND_SERVICE, and
# either runs as uid 0 or can gain the capability back. A non-root process
# regains it by running a setuid-root or cap_net_bind_service file from the
# image, unless allowPrivilegeEscalation: false sets no_new_privs. A
# privileged container keeps every capability.
#
# Input: a list of pods. Output: a sorted list of <namespace>/<pod>.

def setting($pod; $name):
  if (.securityContext // {}) | has($name) then .securityContext[$name]
  else $pod.spec.securityContext[$name]?
  end;

def can_be_root($pod):
  setting($pod; "runAsUser") as $user
  | $user == 0 or ($user == null and setting($pod; "runAsNonRoot") != true);

def can_escalate: .securityContext.allowPrivilegeEscalation != false;

def capability: ascii_upcase | ltrimstr("CAP_");

# containerd applies add: [ALL], then drop: [ALL], then each added and each
# dropped capability, so a single NET_BIND_SERVICE added after drop: [ALL]
# stays, and a single one dropped is gone.
def keeps_bind_capability:
  [.securityContext.capabilities.add[]? | capability] as $add
  | [.securityContext.capabilities.drop[]? | capability] as $drop
  | .securityContext.privileged == true
    or (($drop | index("NET_BIND_SERVICE") | not)
        and (($add | index("NET_BIND_SERVICE")) or ($drop | index("ALL") | not)));

[.[]
 | select(.spec.hostNetwork == true)
 | . as $pod
 | select(any((.spec.initContainers // [])[], .spec.containers[], (.spec.ephemeralContainers // [])[];
              keeps_bind_capability and (can_be_root($pod) or can_escalate)))
 | "\(.metadata.namespace)/\(.metadata.name)"]
| sort
