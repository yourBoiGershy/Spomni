#!/bin/bash
# build-index.sh — walk <store-dir>/people/*.md and emit <store-dir>/index.json
#
# Usage: build-index.sh [store-dir]   (defaults to ".")
#
# For each people/<slug>.md, projects the frontmatter fields defined in
# packages/core/contracts/person.md (tags, org, role, location, last-touch,
# and — per the 1.1.0 optional kind fields, plan 30 — kind, kind_source,
# kind_expires) into a flat, deterministically-ordered index.json keyed by
# slug. Stores without kind fields simply get null kind/kind_source/
# kind_expires columns.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -eu

STORE_DIR="${1:-.}"
PEOPLE_DIR="${STORE_DIR}/people"
INDEX_PATH="${STORE_DIR}/index.json"

if [ ! -d "$PEOPLE_DIR" ]; then
  echo "build-index.sh: no people/ directory found at ${PEOPLE_DIR}" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "build-index.sh: jq is required but not found on PATH" >&2
  exit 1
fi

# Extract the YAML frontmatter block (between the first two '---' lines).
extract_frontmatter() {
  awk '
    /^---$/ { c++; if (c == 2) exit; next }
    c == 1 { print }
  ' "$1"
}

# Extract a single scalar field value from the frontmatter, e.g. "org".
extract_field() {
  fm="$1"
  key="$2"
  printf '%s\n' "$fm" | sed -n "s/^${key}: *//p" | head -1
}

TMP_JSONL="$(mktemp)"
trap 'rm -f "$TMP_JSONL"' EXIT

count=0

# Sort filenames for deterministic processing order.
for f in $(ls "$PEOPLE_DIR"/*.md 2>/dev/null | sort); do
  [ -e "$f" ] || continue

  base="$(basename "$f")"
  slug="${base%.md}"

  fm="$(extract_frontmatter "$f")"

  org="$(extract_field "$fm" org)"
  role="$(extract_field "$fm" role)"
  location="$(extract_field "$fm" location)"
  last_touch="$(extract_field "$fm" last-touch)"
  kind="$(extract_field "$fm" kind)"
  kind_source="$(extract_field "$fm" kind_source)"
  kind_expires="$(extract_field "$fm" kind_expires)"
  tags_raw="$(extract_field "$fm" tags)"

  # tags_raw looks like "[fintech, college-friend]" or "[]" or empty (absent).
  tags_inner="${tags_raw#\[}"
  tags_inner="${tags_inner%\]}"

  if [ -z "$tags_inner" ]; then
    tags_json="[]"
  else
    tags_json="$(printf '%s' "$tags_inner" \
      | tr ',' '\n' \
      | sed 's/^ *//;s/ *$//' \
      | jq -R . \
      | jq -s -c 'map(select(length > 0))')"
  fi

  jq -n \
    --arg slug "$slug" \
    --arg org "$org" \
    --arg role "$role" \
    --arg location "$location" \
    --arg last_touch "$last_touch" \
    --arg kind "$kind" \
    --arg kind_source "$kind_source" \
    --arg kind_expires "$kind_expires" \
    --argjson tags "$tags_json" \
    '{($slug): {
        tags: $tags,
        org: (if $org == "" then null else $org end),
        role: (if $role == "" then null else $role end),
        location: (if $location == "" then null else $location end),
        "last-touch": (if $last_touch == "" then null else $last_touch end),
        kind: (if $kind == "" then null else $kind end),
        kind_source: (if $kind_source == "" then null else $kind_source end),
        kind_expires: (if $kind_expires == "" then null else $kind_expires end)
      }}' >> "$TMP_JSONL"

  count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
  echo '{}' > "$INDEX_PATH"
else
  jq -s 'add' "$TMP_JSONL" | jq -S '.' > "$INDEX_PATH"
fi

echo "indexed ${count} people → ${INDEX_PATH}"
