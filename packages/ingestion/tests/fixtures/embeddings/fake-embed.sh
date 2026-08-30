#!/usr/bin/env bash
# fake-embed.sh — deterministic EMBED_CMD shim for the embeddings test
# suite (packages/ingestion/tests/run-embeddings-tests.sh). Invoked exactly
# per packages/ingestion/specs/embeddings.md's EMBED_CMD contract:
#
#   $EMBED_CMD <model>
#
# with the text to embed piped to stdin; prints a JSON array of numbers
# (the vector) to stdout. No network call, fully deterministic — same text
# in, same vector out, every time.
#
# Vector shape (8 dims), so that semantically-similar fixture people land
# close together under cosine similarity while still being distinguishable
# from unrelated ones:
#
#   dims 0-3 — case-insensitive keyword-bucket counts over the text
#     (grep -oE against the lowercased text, count of non-overlapping
#     matches), one bucket per axis of the fixture store's people:
#       dim0: friend|climb|dinner|book|university   (close personal/friend)
#       dim1: launch|plan|sync|client|invoice|billing (work/transactional)
#       dim2: chat|group|makerspace|neighbourhood   (community/group)
#       dim3: pitch|growth|inbound                  (unsolicited/pitch)
#   dims 4-7 — sha256(text)-derived jitter, one *non-negative* float per
#     dim (first four hex byte-pairs of the digest, mapped to [0, 0.5]).
#     Kept non-negative (like the bucket counts) so every pair of vectors
#     has an all-non-negative dot product — cosine is never negative for
#     any pair, which is what makes --threshold 0.0 merge everyone into a
#     single cluster (a signed jitter component would occasionally push a
#     pair's cosine below 0.0 and fracture that). The magnitude still
#     keeps otherwise-identical-bucket-count texts (e.g. two
#     community-only people, both all-zero on dims 0-3) from ever landing
#     within cosine 0.999 of one another — distinguishable at the highest
#     clustering threshold — while leaving the bucket-count signal
#     dominant enough to drive the 0.80-threshold clustering.
#
# The 8-dim raw vector is L2-normalized before being printed (all-zero
# guarded: an all-zero raw vector — empty text — is printed as-is).
#
# Axis sentences (nearest-confirmed.sh --axis-similarity) fall out of the
# same buckets without special-casing: "business: work relationships —
# ... clients ..." hits dim1 (client); "community: group or scene
# contacts" hits dim2 (group); "friends: real social relationships"
# self-matches dim0 (friend substring of "friends"); family/transactional
# axis text matches no bucket and differs only by jitter — expected and
# fine, this shim only needs to be deterministic, not a real model.

set -eu

text="$(cat -)"
lc="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"

count() {
  # count <regex> — number of non-overlapping matches in the lowercased
  # text; 0 if none.
  printf '%s' "$lc" | grep -oE "$1" 2>/dev/null | wc -l | tr -d ' '
}

b1="$(count 'friend|climb|dinner|book|university')"
b2="$(count 'launch|plan|sync|client|invoice|billing')"
b3="$(count 'chat|group|makerspace|neighbourhood')"
b4="$(count 'pitch|growth|inbound')"

hash="$(printf '%s' "$text" | shasum -a 256 | awk '{print $1}')"

hex_to_jitter() {
  # hex_to_jitter <2-hex-chars> -> non-negative float text in [0, 0.5]
  v=$((16#$1))
  awk -v v="$v" 'BEGIN { printf "%.6f", (v / 255) * 0.5 }'
}

j1="$(hex_to_jitter "${hash:0:2}")"
j2="$(hex_to_jitter "${hash:2:2}")"
j3="$(hex_to_jitter "${hash:4:2}")"
j4="$(hex_to_jitter "${hash:6:2}")"

jq -nc \
  --argjson b1 "$b1" --argjson b2 "$b2" --argjson b3 "$b3" --argjson b4 "$b4" \
  --argjson j1 "$j1" --argjson j2 "$j2" --argjson j3 "$j3" --argjson j4 "$j4" '
  [$b1, $b2, $b3, $b4, $j1, $j2, $j3, $j4] as $raw
  | ($raw | map(. * .) | add | sqrt) as $norm
  | if $norm == 0 then $raw else ($raw | map(. / $norm)) end
'
