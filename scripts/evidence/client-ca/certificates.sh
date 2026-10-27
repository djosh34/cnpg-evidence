#!/usr/bin/env bash
# Prints the certificates in the PEM text on stdin as a sorted JSON list of
# {name, sha256_fingerprint}. ca.crt can hold several certificates.
set -euo pipefail
shopt -s inherit_errexit

each_certificate() {
  local line certificate=
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == '-----BEGIN CERTIFICATE-----' ]]; then
      certificate=
    fi
    certificate+=$line$'\n'
    if [[ $line == '-----END CERTIFICATE-----' ]]; then
      openssl x509 -noout -subject -fingerprint -sha256 -nameopt RFC2253 <<<"$certificate"
    fi
  done
}

# openssl prints two lines per certificate: subject=... and the fingerprint.
each_certificate | jq -Rn '
  [inputs] as $lines
  | [range(0; $lines | length; 2) as $i
     | {name: ($lines[$i] | ltrimstr("subject=")),
        sha256_fingerprint: ($lines[$i + 1] | sub("^[^=]*="; ""))}]
  | sort'
