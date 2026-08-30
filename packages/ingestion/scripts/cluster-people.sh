#!/usr/bin/env bash
# cluster-people.sh — greedy threshold clustering over
# <store>/index/embeddings.jsonl, per packages/ingestion/specs/embeddings.md
# ("cluster-people.sh") and packages/core/contracts/embeddings-index.md
# (a read-only consumer — never writes the artifact, never persists its
# own output; a prompt-batching heuristic only).
#
# Usage:
#   cluster-people.sh <store-dir> [--threshold 0.80] [--scope <slug-list-file>]
#
# Algorithm (iterated over the slug set — every embedded slug, or the
# slugs listed one-per-line in --scope's file — in slug ascending order):
#   1. For the next slug, compute its cosine similarity to every existing
#      cluster's CURRENT exemplar. If any clears --threshold, the slug
#      joins the FIRST such cluster (creation order, not highest score).
#      Otherwise it starts a new cluster as sole member + initial exemplar.
#   2. After all slugs are assigned, recompute each cluster's exemplar
#      once: the member with the highest degree (count of other members
#      in the same cluster whose cosine to it is >= threshold; ties broken
#      by slug ascending). This does not re-trigger reassignment.
#
# Output, one line per (cluster, member) pair, tab-separated:
#   <cluster-id>\t<slug>\t<exemplar:yes|no>
# Cluster ids are c001, c002, ... in creation order. Rows sorted by cluster
# id ascending, exemplar member first (yes before no), then slug ascending.
#
# Unavailable path (probe fails / JSONL absent / scope has no matching
# embeddings): prints "embeddings: unavailable", exits 0, writes nothing.
# This script itself makes no embedding calls (it only reads the existing
# JSONL), so "probe fails" here means the JSONL is simply absent or the
# in-scope candidate set is empty.
#
# Read-only: never writes to <store-dir> or anywhere else.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -eu

if [ $# -lt 1 ]; then
  echo "usage: cluster-people.sh <store-dir> [--threshold 0.80] [--scope <file>]" >&2
  exit 1
fi

STORE_DIR="$1"
shift

THRESHOLD="0.80"
SCOPE_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --threshold)
      [ $# -ge 2 ] || { echo "cluster-people.sh: --threshold requires an argument" >&2; exit 1; }
      THRESHOLD="$2"
      shift 2
      ;;
    --scope)
      [ $# -ge 2 ] || { echo "cluster-people.sh: --scope requires an argument" >&2; exit 1; }
      SCOPE_FILE="$2"
      shift 2
      ;;
    *)
      echo "cluster-people.sh: unrecognized argument '$1'" >&2
      exit 1
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "cluster-people.sh: jq is required but not found on PATH" >&2
  exit 1
fi

EMBEDDINGS_PATH="${STORE_DIR}/index/embeddings.jsonl"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
EMBED_CMD="${EMBED_CMD:-}"

unavailable() {
  echo "embeddings: unavailable"
  exit 0
}

# This script makes no embedding calls itself (it only reads the already
# -computed JSONL), but the spec still gates it on the same availability
# probe as the writer/embedding-calling scripts (skipped when EMBED_CMD is
# set — the shim being present is itself the availability signal).
if [ -z "$EMBED_CMD" ]; then
  curl -s -m 2 -o /dev/null -w '%{http_code}' "${OLLAMA_URL}/api/tags" 2>/dev/null | grep -qE '^2[0-9][0-9]$' || unavailable
fi

[ -f "$EMBEDDINGS_PATH" ] || unavailable

# ---------------------------------------------------------------------------
# Build the in-scope slug set (ascending), restricted to slugs that also
# have an embeddings line and all share the same dims (a dims mismatch
# within the candidate set drops the mismatching member the same way a
# nearest-confirmed dims mismatch is skipped, per the spec's cosine
# definition — "never compared... skipped rather than padded").
# ---------------------------------------------------------------------------
SLUGS_FILE="$(mktemp)"
VECS_JSONL="$(mktemp)"
trap 'rm -f "$SLUGS_FILE" "$VECS_JSONL"' EXIT

if [ -n "$SCOPE_FILE" ]; then
  sort -u "$SCOPE_FILE" > "$SLUGS_FILE"
else
  jq -r '.slug' "$EMBEDDINGS_PATH" | sort -u > "$SLUGS_FILE"
fi

: > "$VECS_JSONL"
while IFS= read -r s; do
  [ -z "$s" ] && continue
  ln="$(jq -c --arg s "$s" 'select(.slug == $s)' "$EMBEDDINGS_PATH" 2>/dev/null | head -1)"
  [ -n "$ln" ] || continue
  printf '%s\n' "$ln" >> "$VECS_JSONL"
done < "$SLUGS_FILE"

if [ ! -s "$VECS_JSONL" ]; then
  unavailable
fi

# Keep only the dims value shared by the majority... per spec, comparisons
# with mismatched dims are simply skipped pairwise; no need to prune the
# member set globally. Members are kept as-is; cosine() below returns null
# (never >= threshold) for a mismatched pair, which correctly prevents that
# pair from ever clustering together.

# ---------------------------------------------------------------------------
# jq cosine helper.
# ---------------------------------------------------------------------------
JQ_COSINE_DEF='
def cosine(a; b):
  if (a | length) != (b | length) then null else
    ([a, b] | transpose | map(.[0] * .[1]) | add) as $dot
    | (a | map(. * .) | add | sqrt) as $na
    | (b | map(. * .) | add | sqrt) as $nb
    | if $na == 0 or $nb == 0 then null else $dot / ($na * $nb) end
  end;
def round4: (. * 10000 | round) / 10000;
'

cosine_of() {
  # cosine_of <slugA> <slugB> -> rounded cosine (bare JSON number text) or
  # nothing at all when the pair is null (dims mismatch / zero vector) —
  # deliberately NOT tostring'd into a quoted string: a quoted string sorts
  # after any number in jq's ordering, which would make a later `$c >= $t`
  # comparison always true regardless of the actual value.
  a="$1"
  b="$2"
  va="$(jq -c --arg s "$a" 'select(.slug == $s) | .vector' "$VECS_JSONL" | head -1)"
  vb="$(jq -c --arg s "$b" 'select(.slug == $s) | .vector' "$VECS_JSONL" | head -1)"
  jq -n "$JQ_COSINE_DEF"'(cosine($a; $b)) as $c | if $c == null then empty else ($c | round4) end' --argjson a "$va" --argjson b "$vb"
}

# ---------------------------------------------------------------------------
# Step 1: greedy assignment, slug ascending.
# CLUSTERS_FILE: one line per cluster, format: <cluster-id>\t<exemplar-slug>
# MEMBERS_FILE: one line per (cluster-id, slug) assignment, in assignment
# order.
# ---------------------------------------------------------------------------
CLUSTERS_FILE="$(mktemp)"
MEMBERS_FILE="$(mktemp)"
trap 'rm -f "$SLUGS_FILE" "$VECS_JSONL" "$CLUSTERS_FILE" "$MEMBERS_FILE"' EXIT
: > "$CLUSTERS_FILE"
: > "$MEMBERS_FILE"

next_cluster_num=1

# Read the ordered, embedded slug set (ascending, only those with a vector).
ORDERED_SLUGS="$(jq -r '.slug' "$VECS_JSONL" | sort -u)"

while IFS= read -r slug; do
  [ -z "$slug" ] && continue

  assigned_cluster=""
  if [ -s "$CLUSTERS_FILE" ]; then
    while IFS="$(printf '\t')" read -r cid exemplar; do
      [ -z "$cid" ] && continue
      cos="$(cosine_of "$slug" "$exemplar")"
      [ -n "$cos" ] || continue
      ge="$(jq -n --argjson c "$cos" --argjson t "$THRESHOLD" '$c >= $t')"
      if [ "$ge" = "true" ]; then
        assigned_cluster="$cid"
        break
      fi
    done < "$CLUSTERS_FILE"
  fi

  if [ -z "$assigned_cluster" ]; then
    cid="$(printf 'c%03d' "$next_cluster_num")"
    next_cluster_num=$((next_cluster_num + 1))
    printf '%s\t%s\n' "$cid" "$slug" >> "$CLUSTERS_FILE"
    assigned_cluster="$cid"
  fi

  printf '%s\t%s\n' "$assigned_cluster" "$slug" >> "$MEMBERS_FILE"
done <<EOF
$ORDERED_SLUGS
EOF

# ---------------------------------------------------------------------------
# Step 2: recompute each cluster's exemplar once — highest degree member,
# ties broken by slug ascending.
# ---------------------------------------------------------------------------
FINAL_OUT="$(mktemp)"
trap 'rm -f "$SLUGS_FILE" "$VECS_JSONL" "$CLUSTERS_FILE" "$MEMBERS_FILE" "$FINAL_OUT"' EXIT
: > "$FINAL_OUT"

while IFS="$(printf '\t')" read -r cid _exemplar_ignored; do
  [ -z "$cid" ] && continue

  MEMBERS="$(awk -F'\t' -v c="$cid" '$1 == c { print $2 }' "$MEMBERS_FILE" | sort -u)"

  best_slug=""
  best_degree=-1
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    degree=0
    while IFS= read -r other; do
      [ -z "$other" ] && continue
      [ "$other" = "$m" ] && continue
      cos="$(cosine_of "$m" "$other")"
      [ -n "$cos" ] || continue
      ge="$(jq -n --argjson c "$cos" --argjson t "$THRESHOLD" '$c >= $t')"
      [ "$ge" = "true" ] && degree=$((degree + 1))
    done <<EOF2
$MEMBERS
EOF2
    if [ "$degree" -gt "$best_degree" ]; then
      best_degree="$degree"
      best_slug="$m"
    elif [ "$degree" -eq "$best_degree" ]; then
      if [ -n "$best_slug" ] && [ "$m" \< "$best_slug" ]; then
        best_slug="$m"
      fi
    fi
  done <<EOF3
$MEMBERS
EOF3

  while IFS= read -r m; do
    [ -z "$m" ] && continue
    if [ "$m" = "$best_slug" ]; then
      printf '%s\t%s\tyes\n' "$cid" "$m" >> "$FINAL_OUT"
    else
      printf '%s\t%s\tno\n' "$cid" "$m" >> "$FINAL_OUT"
    fi
  done <<EOF4
$MEMBERS
EOF4
done < "$CLUSTERS_FILE"

# ---------------------------------------------------------------------------
# Final sort: cluster id ascending, exemplar (yes) before (no), slug asc.
# ---------------------------------------------------------------------------
sort -t "$(printf '\t')" -k1,1 -k3,3r -k2,2 "$FINAL_OUT"
