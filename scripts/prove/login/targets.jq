# Lists every LoadBalancer address and port.
# Usage: jq -r -f targets.jq < service.json
# Exit: 0 with targets or no addresses, nonzero for invalid input.
.spec.ports[].port as $port
| .status.loadBalancer.ingress[]?
| "\(.ip // .hostname):\($port)"
