#!/usr/bin/env bash
# embed-people.sh — compute/refresh <store>/index/embeddings.jsonl from
# people/*.md + interactions/*.md, per packages/ingestion/specs/embeddings.md
# and packages/core/contracts/embeddings-index.md (sole writer of that
# artifact).
#
# Usage:
#   embed-people.sh <store-dir> [--scope <file-of-slugs>] [--today <iso>]
#
# <store-dir> must contain a people/ directory. `--scope <file>` restricts
# the set of people considered for re-embedding to the slugs listed
# one-per-line in that file (people/*.md outside the scope are left
# untouched in the existing JSONL — they are neither dropped nor
# re-embedded). Without --scope, every people/<slug>.md is considered.
#
# `--today <iso>` (or the EMBED_NOW env var) overrides the `embedded_at`
# timestamp written for freshly-(re)embedded lines — a determinism hook for
# tests; default is `date -u +%Y-%m-%dT%H:%M:%SZ` at write time.
#
# Content assembled per person (see spec "Content per person"): frontmatter
# fields name/org/role/tags/how-met (each on its own "key: value" line, a
# missing field simply omitted), the body sections verbatim in file order,
# then up to the 20 most-recent (newest-first) filed interaction summary
# lines ("<date> <title> — <summary line>") for interactions linking
# `[[slug]]`. content_hash = sha256 (shasum -a 256) of that exact joined
# text. Re-embedding for a slug happens only when the freshly-assembled
# hash differs from the stored content_hash for that slug — an unchanged
# hash reuses the existing line as-is (no re-embed call, no embedded_at
# bump).
#
# Embedding resolution: EMBED_CMD (if set) invoked as `$EMBED_CMD <model>`
# with the text piped to stdin, must print a JSON array of numbers; else
# local Ollama (OLLAMA_URL, default http://localhost:11434; EMBED_MODEL,
# default nomic-embed-text) via POST /api/embeddings, falling back once to
# POST /api/embed on failure. Never a cloud endpoint — see spec "Locality +
# optionality".
#
# Normalization invariant: every vector resolved above (whichever of the
# three paths produced it) is L2-normalized to unit length before it is
# written to embeddings.jsonl — |v| = 1 within float precision, per
# packages/core/contracts/embeddings-index.md's `vector` field note. This
# lets every consumer's cosine similarity reduce to a plain dot product. A
# zero vector (norm 0) cannot be normalized and is written as-is, with a
# warning to stderr.
#
# Unavailable behavior: when EMBED_CMD is unset and the Ollama availability
# probe (`curl -s -m 2 "$OLLAMA_URL/api/tags"`) fails, prints exactly
# "embeddings: unavailable" to stdout, exits 0, and touches nothing (no
# partial write). A slug that needs a fresh embed but whose embed call
# fails mid-run degrades the whole run the same way.
#
# Write discipline: the whole file is rewritten atomically (temp file +
# mv), lines sorted by slug ascending, dropping any slug no longer present
# under people/. On success, prints:
#   embedded: <n> refreshed, <m> unchanged, <k> dropped
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -eu

if [ $# -lt 1 ]; then
  echo "usage: embed-people.sh <store-dir> [--scope <file>] [--today <iso>]" >&2
  exit 1
fi

STORE_DIR="$1"
shift

SCOPE_FILE=""
TODAY_OVERRIDE="${EMBED_NOW:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --scope)
      [ $# -ge 2 ] || { echo "embed-people.sh: --scope requires an argument" >&2; exit 1; }
      SCOPE_FILE="$2"
      shift 2
      ;;
    --today)
      [ $# -ge 2 ] || { echo "embed-people.sh: --today requires an argument" >&2; exit 1; }
      TODAY_OVERRIDE="$2"
      shift 2
      ;;
    *)
      echo "embed-people.sh: unrecognized argument '$1'" >&2
      exit 1
      ;;
  esac
done

PEOPLE_DIR="${STORE_DIR}/people"
INTERACTIONS_DIR="${STORE_DIR}/interactions"
INDEX_DIR="${STORE_DIR}/index"
OUT_PATH="${INDEX_DIR}/embeddings.jsonl"

if [ ! -d "$PEOPLE_DIR" ]; then
  echo "embed-people.sh: no people/ directory found at ${PEOPLE_DIR}" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "embed-people.sh: jq is required but not found on PATH" >&2
  exit 1
fi

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"
EMBED_CMD="${EMBED_CMD:-}"

# ---------------------------------------------------------------------------
# Availability probe (skipped when EMBED_CMD is set).
# ---------------------------------------------------------------------------
if [ -z "$EMBED_CMD" ]; then
  if ! curl -s -m 2 -o /dev/null -w '%{http_code}' "${OLLAMA_URL}/api/tags" 2>/dev/null | grep -qE '^2[0-9][0-9]$'; then
    echo "embeddings: unavailable"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# embed_text <text> — prints a JSON array of numbers on stdout, or nothing
# (with a status file marking failure) if unavailable.
# ---------------------------------------------------------------------------
EMBED_FAIL_FLAG="$(mktemp)"
rm -f "$EMBED_FAIL_FLAG"

embed_text() {
  text="$1"

  if [ -n "$EMBED_CMD" ]; then
    vec="$(printf '%s' "$text" | $EMBED_CMD "$EMBED_MODEL" 2>/dev/null || true)"
    if printf '%s' "$vec" | jq -e 'type == "array" and (all(.[]; type == "number"))' >/dev/null 2>&1; then
      printf '%s' "$vec" | jq -c '.'
      return 0
    fi
    : > "$EMBED_FAIL_FLAG"
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

  : > "$EMBED_FAIL_FLAG"
  return 1
}

# ---------------------------------------------------------------------------
# extract_frontmatter <file> — the YAML block between the first two '---'
# lines.
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

# ---------------------------------------------------------------------------
# extract_body <file> — everything after the frontmatter's closing '---'.
# ---------------------------------------------------------------------------
extract_body() {
  awk '
    /^---$/ { n++; next }
    n >= 2 { print }
  ' "$1"
}

# ---------------------------------------------------------------------------
# build_content <slug> <file> — the exact joined text per spec.
# ---------------------------------------------------------------------------
build_content() {
  slug="$1"
  file="$2"

  fm="$(extract_frontmatter "$file")"

  {
    name="$(extract_field "$fm" name)"
    [ -n "$name" ] && printf 'name: %s\n' "$name"

    org="$(extract_field "$fm" org)"
    [ -n "$org" ] && printf 'org: %s\n' "$org"

    role="$(extract_field "$fm" role)"
    [ -n "$role" ] && printf 'role: %s\n' "$role"

    tags="$(extract_field "$fm" tags)"
    [ -n "$tags" ] && printf 'tags: %s\n' "$tags"

    how_met="$(extract_field "$fm" how-met)"
    [ -n "$how_met" ] && printf 'how-met: %s\n' "$how_met"

    extract_body "$file"

    # Filed interactions linking [[slug]], newest first, capped at 20.
    if [ -d "$INTERACTIONS_DIR" ]; then
      for f in $(ls "$INTERACTIONS_DIR"/*.md 2>/dev/null | sort -r); do
        [ -e "$f" ] || continue
        ifm="$(extract_frontmatter "$f")"
        people_line="$(extract_field "$ifm" people)"
        case "$people_line" in
          *"[[${slug}]]"*) ;;
          *) continue ;;
        esac
        idate="$(extract_field "$ifm" date)"
        ibody="$(extract_body "$f")"
        ititle="$(printf '%s\n' "$ibody" | sed -n 's/^#\{1,6\} *//p' | head -1)"
        isummary="$(printf '%s\n' "$ibody" | awk '
          BEGIN { in_summary = 0 }
          /^## Summary[ \t]*$/ { in_summary = 1; next }
          /^## / { if (in_summary) exit }
          in_summary && NF { print; exit }
        ')"
        printf '%s %s — %s\n' "$idate" "$ititle" "$isummary"
      done | head -20
    fi
  }
}

# ---------------------------------------------------------------------------
# Load the existing JSONL (if any) into a lookup file: slug<TAB>line
# ---------------------------------------------------------------------------
EXISTING="$(mktemp)"
if [ -f "$OUT_PATH" ]; then
  jq -c '.' "$OUT_PATH" 2>/dev/null | while IFS= read -r ln; do
    s="$(printf '%s' "$ln" | jq -r '.slug')"
    printf '%s\t%s\n' "$s" "$ln"
  done > "$EXISTING" || true
else
  : > "$EXISTING"
fi

existing_line_for() {
  awk -F'\t' -v s="$1" '$1 == s { print; exit }' "$EXISTING" | cut -f2-
}

existing_hash_for() {
  ln="$(existing_line_for "$1")"
  if [ -n "$ln" ]; then
    printf '%s' "$ln" | jq -r '.content_hash // empty'
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Scope set.
# ---------------------------------------------------------------------------
in_scope() {
  [ -z "$SCOPE_FILE" ] && return 0
  grep -qx "$1" "$SCOPE_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Main pass.
# ---------------------------------------------------------------------------
TMP_OUT="$(mktemp)"
CLEANUP() { rm -f "$EXISTING" "$TMP_OUT" "$EMBED_FAIL_FLAG"; }
trap CLEANUP EXIT

refreshed=0
unchanged=0
dropped=0

if [ -n "$TODAY_OVERRIDE" ]; then
  now_iso="$TODAY_OVERRIDE"
else
  now_iso=""
fi

for f in $(ls "$PEOPLE_DIR"/*.md 2>/dev/null | sort); do
  [ -e "$f" ] || continue
  base="$(basename "$f")"
  slug="${base%.md}"

  if ! in_scope "$slug"; then
    # Out of scope: carry the existing line forward unchanged, if any.
    ln="$(existing_line_for "$slug")"
    if [ -n "$ln" ]; then
      printf '%s\n' "$ln" >> "$TMP_OUT"
    fi
    continue
  fi

  content="$(build_content "$slug" "$f")"
  hash="$(printf '%s' "$content" | shasum -a 256 | awk '{print $1}')"
  old_hash="$(existing_hash_for "$slug")"

  if [ -n "$old_hash" ] && [ "$old_hash" = "$hash" ]; then
    ln="$(existing_line_for "$slug")"
    printf '%s\n' "$ln" >> "$TMP_OUT"
    unchanged=$((unchanged + 1))
    continue
  fi

  vec="$(embed_text "$content")" || { rm -f "$TMP_OUT" "$EXISTING" "$EMBED_FAIL_FLAG"; trap - EXIT; echo "embeddings: unavailable"; exit 0; }

  # L2-normalize to unit length (see header "Normalization invariant"). A
  # zero vector cannot be normalized and is passed through unchanged, with
  # a warning to stderr.
  norm="$(printf '%s' "$vec" | jq '(map(. * .) | add | sqrt)')"
  if [ "$norm" = "0" ]; then
    echo "embed-people.sh: warning: zero vector for slug '${slug}', left unnormalized" >&2
  else
    vec="$(printf '%s' "$vec" | jq -c --argjson n "$norm" 'map(. / $n)')"
  fi

  dims="$(printf '%s' "$vec" | jq 'length')"

  if [ -n "$now_iso" ]; then
    embedded_at="$now_iso"
  else
    embedded_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi

  jq -nc \
    --arg slug "$slug" \
    --arg model "$EMBED_MODEL" \
    --argjson dims "$dims" \
    --argjson vector "$vec" \
    --arg embedded_at "$embedded_at" \
    --arg content_hash "$hash" \
    '{slug: $slug, model: $model, dims: $dims, vector: $vector, embedded_at: $embedded_at, content_hash: $content_hash}' \
    >> "$TMP_OUT"

  refreshed=$((refreshed + 1))
done

# Count dropped: slugs present in the old file but no longer under people/
# and not carried forward (i.e. truly absent from people/).
if [ -s "$EXISTING" ]; then
  while IFS= read -r ln; do
    s="$(printf '%s' "$ln" | cut -f1)"
    [ -z "$s" ] && continue
    if [ ! -f "${PEOPLE_DIR}/${s}.md" ]; then
      dropped=$((dropped + 1))
    fi
  done < "$EXISTING"
fi

mkdir -p "$INDEX_DIR"
TMP_FINAL="$(mktemp)"
if [ -s "$TMP_OUT" ]; then
  jq -c '.' "$TMP_OUT" | jq -s -c 'sort_by(.slug) | .[]' > "$TMP_FINAL"
else
  : > "$TMP_FINAL"
fi
mv "$TMP_FINAL" "$OUT_PATH"

echo "embedded: ${refreshed} refreshed, ${unchanged} unchanged, ${dropped} dropped"
