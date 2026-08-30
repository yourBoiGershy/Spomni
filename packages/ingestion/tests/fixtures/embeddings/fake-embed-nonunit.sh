#!/usr/bin/env bash
# fake-embed-nonunit.sh — deterministic EMBED_CMD shim used ONLY by the
# sabotage proof in run-embeddings-tests.sh (assertion 12). Unlike
# fake-embed.sh, this shim deliberately prints a raw, non-normalized
# vector (no L2 normalization applied) so that a sabotaged embed-people.sh
# with the normalization step removed is exercised against genuinely
# non-unit vectors — proving the norm assertion actually bites rather than
# passing vacuously because the shim already hands back unit vectors.
#
# Same `$EMBED_CMD <model>` contract as fake-embed.sh: text piped to
# stdin, JSON array of numbers on stdout. Deterministic: length-derived
# raw vector, no normalization.

set -eu

text="$(cat -)"
len="${#text}"

jq -nc --argjson len "$len" '[$len, $len + 1, $len + 2]'
