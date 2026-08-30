#!/usr/bin/env bash
# nearest-confirmed.sh — neighbor priors + axis-similarity over
# <store>/index/embeddings.jsonl, per packages/ingestion/specs/embeddings.md
# and packages/core/contracts/embeddings-index.md (a read-only consumer of
# that artifact — never writes it).
#
# Usage:
#   nearest-confirmed.sh <store-dir> <slug> [--k 3]
#   nearest-confirmed.sh --axis-similarity <store-dir> [--today <iso>]
#
# Default mode: the nearest people to <slug> among CONFIRMED candidates —
# people whose kind_source is `stated-by-user` (read from <store>/index.json
# when that entry carries a "kind_source" key, else falling back to
# grepping people/<slug>.md's frontmatter directly — index.json's
# kind_source column is a concurrent addition this script tolerates being
# absent), excluding <slug> itself. Output, one line per result, tab
# separated:
#   <slug>\t<kind>\t<tier|->\t<cos>
# `<tier|->` and `<kind>` are read from the candidate's own
# people/<slug>.md frontmatter (`tier` literal `-` if unset). Sorted by
# cosine descending, ties broken by slug ascending, truncated to the top k
# (default 3, cosine rounded to 4 decimals). If <slug> has no embeddings
# line, no candidate has a matching `dims`, or the confirmed candidate set
# is empty, prints "embeddings: unavailable" and exits 0.
#
# --axis-similarity mode (mutually exclusive, no <slug>): embeds the five
# fixed axis sentences (business/friends/family/community/transactional)
# via EMBED_CMD (test shim, `$EMBED_CMD <model>` with text on stdin -> JSON
# number array on stdout) or local Ollama (OLLAMA_URL, EMBED_MODEL; POST
# /api/embeddings falling back to /api/embed) — never a cloud endpoint. For
# each axis, computes the mean cosine similarity (rounded to 4 decimals)
# between that axis's vector and every person's vector who has at least one
# interaction in the trailing 90 days (relative to --today, default today's
# UTC date) and whose `dims` matches the axis vectors' dims. Prints a single
# JSON object:
#   {"business":..,"friends":..,"family":..,"community":..,"transactional":..,"model":".."}
# If the JSONL is absent, Ollama/EMBED_CMD is unavailable, or the eligible
# person set (post interaction-window + dims filters) is empty, prints
# "embeddings: unavailable" and exits 0.
#
# Read-only: never writes to <store-dir> or anywhere else.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -eu

if ! command -v jq >/dev/null 2>&1; then
  echo "nearest-confirmed.sh: jq is required but not found on PATH" >&2
  exit 1
fi

AXIS_MODE=0
STORE_DIR=""
SLUG=""
K=3
TODAY_OVERRIDE="${EMBED_NOW:-}"

if [ $# -ge 1 ] && [ "$1" = "--axis-similarity" ]; then
  AXIS_MODE=1
  shift
  if [ $# -lt 1 ]; then
    echo "usage: nearest-confirmed.sh --axis-similarity <store-dir> [--today <iso>]" >&2
    exit 1
  fi
  STORE_DIR="$1"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --today)
        [ $# -ge 2 ] || { echo "nearest-confirmed.sh: --today requires an argument" >&2; exit 1; }
        TODAY_OVERRIDE="$2"
        shift 2
        ;;
      *)
        echo "nearest-confirmed.sh: unrecognized argument '$1'" >&2
        exit 1
        ;;
    esac
  done
else
  if [ $# -lt 2 ]; then
    echo "usage: nearest-confirmed.sh <store-dir> <slug> [--k 3]" >&2
    exit 1
  fi
  STORE_DIR="$1"
  SLUG="$2"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --k)
        [ $# -ge 2 ] || { echo "nearest-confirmed.sh: --k requires an argument" >&2; exit 1; }
        K="$2"
        shift 2
        ;;
      *)
        echo "nearest-confirmed.sh: unrecognized argument '$1'" >&2
        exit 1
        ;;
    esac
  done
fi

EMBEDDINGS_PATH="${STORE_DIR}/index/embeddings.jsonl"
PEOPLE_DIR="${STORE_DIR}/people"
INDEX_JSON="${STORE_DIR}/index.json"

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"
EMBED_CMD="${EMBED_CMD:-}"

unavailable() {
  echo "embeddings: unavailable"
  exit 0
}

[ -f "$EMBEDDINGS_PATH" ] || unavailable

# ---------------------------------------------------------------------------
# extract_frontmatter <file> / extract_field <fm> <key>
# ---------------------------------------------------------------------------
extract_frontmatter() {
  awk '
    /^---$/ { c++; if (c == 2) exit; next }
    c == 1 { print }
  ' "$1"
}

extract_field() {
  fm="$1"
  key="$2"
  printf '%s\n' "$fm" | sed -n "s/^${key}: *//p" | head -1
}

get_kind_source() {
  slug="$1"
  if [ -f "$INDEX_JSON" ]; then
    has="$(jq -r --arg s "$slug" '.[$s] | if type == "object" and has("kind_source") then "yes" else "no" end' "$INDEX_JSON" 2>/dev/null || echo "no")"
    if [ "$has" = "yes" ]; then
      jq -r --arg s "$slug" '.[$s].kind_source // empty' "$INDEX_JSON" 2>/dev/null || true
      return 0
    fi
  fi
  pf="${PEOPLE_DIR}/${slug}.md"
  if [ -f "$pf" ]; then
    fm="$(extract_frontmatter "$pf")"
    extract_field "$fm" kind_source
  fi
  return 0
}

get_kind() {
  slug="$1"
  pf="${PEOPLE_DIR}/${slug}.md"
  if [ -f "$pf" ]; then
    fm="$(extract_frontmatter "$pf")"
    extract_field "$fm" kind
  fi
  return 0
}

get_tier() {
  slug="$1"
  pf="${PEOPLE_DIR}/${slug}.md"
  if [ ! -f "$pf" ]; then
    printf '%s' "-"
    return 0
  fi
  fm="$(extract_frontmatter "$pf")"
  t="$(extract_field "$fm" tier)"
  if [ -z "$t" ]; then
    printf '%s' "-"
  else
    printf '%s' "$t"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# embed_text <text> — same resolution as embed-people.sh. Prints a JSON
# array of numbers on success; returns 1 on any failure.
# ---------------------------------------------------------------------------
embed_text() {
  text="$1"

  if [ -n "$EMBED_CMD" ]; then
    vec="$(printf '%s' "$text" | $EMBED_CMD "$EMBED_MODEL" 2>/dev/null || true)"
    if printf '%s' "$vec" | jq -e 'type == "array" and (all(.[]; type == "number"))' >/dev/null 2>&1; then
      printf '%s' "$vec" | jq -c '.'
      return 0
    fi
    return 1
  fi

  if ! curl -s -m 2 -o /dev/null -w '%{http_code}' "${OLLAMA_URL}/api/tags" 2>/dev/null | grep -qE '^2[0-9][0-9]$'; then
    return 1
  fi

  body="$(jq -n --arg model "$EMBED_MODEL" --arg prompt "$text" '{model: $model, prompt: $prompt}')"
  resp="$(curl -s -m 30 -X POST "${OLLAMA_URL}/api/embeddings" -d "$body" 2>/dev/null || true)"
  vec="$(printf '%s' "$resp" | jq -c '.embedding // empty' 2>/dev/null || true)"
  if printf '%s' "$vec" | jq -e 'type == "array" and (all(.[]; type == "number"))' >/dev/null 2>&1; then
    printf '%s' "$vec"
    return 0
  fi

  body2="$(jq -n --arg model "$EMBED_MODEL" --arg input "$text" '{model: $model, input: $input}')"
  resp2="$(curl -s -m 30 -X POST "${OLLAMA_URL}/api/embed" -d "$body2" 2>/dev/null || true)"
  vec2="$(printf '%s' "$resp2" | jq -c '.embeddings[0] // empty' 2>/dev/null || true)"
  if printf '%s' "$vec2" | jq -e 'type == "array" and (all(.[]; type == "number"))' >/dev/null 2>&1; then
    printf '%s' "$vec2"
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# jq cosine helper, shared definition.
# ---------------------------------------------------------------------------
JQ_COSINE_DEF='
def cosine(a; b):
  ([a, b] | transpose | map(.[0] * .[1]) | add) as $dot
  | (a | map(. * .) | add | sqrt) as $na
  | (b | map(. * .) | add | sqrt) as $nb
  | if $na == 0 or $nb == 0 then null else $dot / ($na * $nb) end;
def round4: (. * 10000 | round) / 10000;
'

if [ "$AXIS_MODE" -eq 1 ]; then
  # -------------------------------------------------------------------------
  # --axis-similarity
  # -------------------------------------------------------------------------
  if [ -n "$TODAY_OVERRIDE" ]; then
    today="$TODAY_OVERRIDE"
  else
    today="$(date -u +%Y-%m-%d)"
  fi
  window_start="$(date -j -v-90d -f '%Y-%m-%d' "$today" +%Y-%m-%d 2>/dev/null || date -u -d "${today} -90 days" +%Y-%m-%d)"

  AXIS_NAMES="business friends family community transactional"
  axis_text_for() {
    case "$1" in
      business) printf '%s' 'business: work relationships — colleagues, clients, partners, deals, hiring' ;;
      friends) printf '%s' 'friends: real social relationships — people the user socializes with by choice' ;;
      family) printf '%s' 'family: relatives and family-equivalent relationships' ;;
      community) printf '%s' 'community: group or scene contacts — shared activity, not individual closeness' ;;
      transactional) printf '%s' 'transactional: vendor or service relationships — no personal relationship rhythm' ;;
    esac
  }

  AXIS_JSONL="$(mktemp)"
  trap 'rm -f "$AXIS_JSONL"' EXIT

  axis_dims=""
  for axis in $AXIS_NAMES; do
    text="$(axis_text_for "$axis")"
    vec="$(embed_text "$text")" || unavailable
    dims="$(printf '%s' "$vec" | jq 'length')"
    if [ -z "$axis_dims" ]; then
      axis_dims="$dims"
    elif [ "$dims" != "$axis_dims" ]; then
      unavailable
    fi
    jq -nc --arg axis "$axis" --argjson vector "$vec" '{axis: $axis, vector: $vector}' >> "$AXIS_JSONL"
  done

  # Eligible people: >=1 interaction with date >= window_start, dims match.
  INTERACTIONS_DIR="${STORE_DIR}/interactions"
  ELIGIBLE_SLUGS="$(mktemp)"
  trap 'rm -f "$AXIS_JSONL" "$ELIGIBLE_SLUGS"' EXIT
  : > "$ELIGIBLE_SLUGS"
  if [ -d "$INTERACTIONS_DIR" ]; then
    for f in "$INTERACTIONS_DIR"/*.md; do
      [ -e "$f" ] || continue
      fm="$(extract_frontmatter "$f")"
      idate="$(extract_field "$fm" date)"
      [ -n "$idate" ] || continue
      if [ "$idate" \< "$window_start" ]; then
        continue
      fi
      people_line="$(extract_field "$fm" people)"
      printf '%s\n' "$people_line" | grep -oE '\[\[[a-z0-9-]+\]\]' | sed 's/\[\[//;s/\]\]//' >> "$ELIGIBLE_SLUGS"
    done
  fi
  sort -u "$ELIGIBLE_SLUGS" -o "$ELIGIBLE_SLUGS"

  PEOPLE_VEC_JSONL="$(mktemp)"
  trap 'rm -f "$AXIS_JSONL" "$ELIGIBLE_SLUGS" "$PEOPLE_VEC_JSONL"' EXIT
  : > "$PEOPLE_VEC_JSONL"
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    ln="$(jq -c --arg s "$s" 'select(.slug == $s)' "$EMBEDDINGS_PATH" 2>/dev/null | head -1)"
    [ -z "$ln" ] && continue
    d="$(printf '%s' "$ln" | jq '.dims')"
    [ "$d" = "$axis_dims" ] || continue
    printf '%s\n' "$ln" >> "$PEOPLE_VEC_JSONL"
  done < "$ELIGIBLE_SLUGS"

  if [ ! -s "$PEOPLE_VEC_JSONL" ]; then
    unavailable
  fi

  result="$(jq -n "$JQ_COSINE_DEF"'
    ($axes | map({(.axis): .vector}) | add) as $axismap
    | ($people | map(.vector)) as $pvecs
    | {
        business: (($pvecs | map(cosine($axismap.business; .)) | add / length) | round4),
        friends: (($pvecs | map(cosine($axismap.friends; .)) | add / length) | round4),
        family: (($pvecs | map(cosine($axismap.family; .)) | add / length) | round4),
        community: (($pvecs | map(cosine($axismap.community; .)) | add / length) | round4),
        transactional: (($pvecs | map(cosine($axismap.transactional; .)) | add / length) | round4),
        model: $model
      }
  ' --slurpfile axes "$AXIS_JSONL" --slurpfile people "$PEOPLE_VEC_JSONL" --arg model "$EMBED_MODEL")"

  printf '%s\n' "$result"
  exit 0
fi

# -----------------------------------------------------------------------------
# Default mode: nearest confirmed
# -----------------------------------------------------------------------------
QUERY_LINE="$(jq -c --arg s "$SLUG" 'select(.slug == $s)' "$EMBEDDINGS_PATH" 2>/dev/null | head -1)"
[ -n "$QUERY_LINE" ] || unavailable

QUERY_DIMS="$(printf '%s' "$QUERY_LINE" | jq '.dims')"
QUERY_VECTOR="$(printf '%s' "$QUERY_LINE" | jq -c '.vector')"

CANDIDATES="$(mktemp)"
trap 'rm -f "$CANDIDATES"' EXIT

jq -c --arg s "$SLUG" 'select(.slug != $s)' "$EMBEDDINGS_PATH" > "$CANDIDATES"

RESULTS="$(mktemp)"
trap 'rm -f "$CANDIDATES" "$RESULTS"' EXIT
: > "$RESULTS"

while IFS= read -r ln; do
  [ -z "$ln" ] && continue
  cslug="$(printf '%s' "$ln" | jq -r '.slug')"
  cdims="$(printf '%s' "$ln" | jq '.dims')"
  [ "$cdims" = "$QUERY_DIMS" ] || continue

  ks="$(get_kind_source "$cslug")"
  [ "$ks" = "stated-by-user" ] || continue

  ckind="$(get_kind "$cslug")"
  [ -n "$ckind" ] || ckind="-"
  ctier="$(get_tier "$cslug")"

  cvec="$(printf '%s' "$ln" | jq -c '.vector')"
  cos="$(jq -n "$JQ_COSINE_DEF"' cosine($a; $b) | round4' --argjson a "$QUERY_VECTOR" --argjson b "$cvec")"

  printf '%s\t%s\t%s\t%s\n' "$cslug" "$ckind" "$ctier" "$cos" >> "$RESULTS"
done < "$CANDIDATES"

if [ ! -s "$RESULTS" ]; then
  unavailable
fi

case "$K" in
  ''|*[!0-9]*) K=3 ;;
esac

sort -t "$(printf '\t')" -k4,4gr -k1,1 "$RESULTS" | head -n "$K"
