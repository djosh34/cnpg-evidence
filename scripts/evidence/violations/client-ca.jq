# Rule 1 for the client_ca section: client certificates are checked against
# the caSecret from the values, holding exactly the certificates of --ca.
#
# Input: {facts, values, expected_ca}. Output: a list of violations, see at in common.jq.

include "common";

def certificate: "\(.name) (sha256 \(.sha256_fingerprint))";

.facts.client_ca as $ca
| .values.caSecret as $expected_secret
| .expected_ca as $expected
| [
    (if $ca.secret != $expected_secret then "rule 1: client certificates are checked against secret \($ca.secret), not \($expected_secret)" | at(["client_ca", "secret"])
     else empty end),
    ($ca.certificates | extra($expected) | "rule 1: client CA secret \($ca.secret) also trusts \(certificate)" | at(["client_ca", "certificates"])),
    ($expected | missing($ca.certificates) | "rule 1: client CA secret \($ca.secret) lacks \(certificate)" | at(["client_ca", "certificates"]))
  ]
