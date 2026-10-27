# Helpers the violation sections share. Each section includes it with
# `include "common";`, run as jq -L scripts/evidence/violations.

def includes($item): any(.[]; . == $item);

# The items of a list that the other list lacks, once each.
def extra($expected): . - $expected | unique[];
def missing($actual): . - $actual | unique[];
