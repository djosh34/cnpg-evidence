# Helpers the violation sections share. Each section includes it with
# `include "common";`, run as jq -L scripts/evidence/violations.

def includes($item): any(.[]; . == $item);

# A violation: its sentence, and the path of the evidence value it is about,
# as the keys down to it.
def at($path): {path: $path, sentence: .};

# The items of a list that the other list lacks, once each.
def extra($expected): . - $expected | unique[];
def missing($actual): . - $actual | unique[];
