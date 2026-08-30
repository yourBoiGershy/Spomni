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
# Perf (plan 38 unit B1): the whole people/ tree is walked in a SINGLE awk
# process (one JSON object per line to stdout), followed by exactly two jq
# processes (`jq -s add | jq -S .`) — O(1) process spawns regardless of
# person count, unlike the original per-person jq/sed/awk pipeline. Output
# is byte-identical to that version (locked by
# packages/core/tests/test-build-index.sh's goldens).
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.
# BSD awk/sed compatible (macOS).

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

# Sort filenames for deterministic processing order, and collect them as
# positional params (bash 3.2 portable — no arrays needed).
count=0
set --
for f in $(ls "$PEOPLE_DIR"/*.md 2>/dev/null | sort); do
  [ -e "$f" ] || continue
  set -- "$@" "$f"
  count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
  echo '{}' > "$INDEX_PATH"
else
  awk '
    # Escape a scalar frontmatter value for embedding in a JSON string.
    function jesc(s) {
      gsub(/\\/, "\\\\", s)
      gsub(/"/, "\\\"", s)
      gsub(/\t/, "\\t", s)
      return s
    }

    # Render a scalar as a JSON string literal, or null if it was absent/
    # empty — matching extract_field + the old `if $x == "" then null`
    # projection exactly.
    function jv(v) {
      if (v == "") return "null"
      return "\"" jesc(v) "\""
    }

    function reset() {
      slug = ""; org = ""; role = ""; location = ""; last_touch = ""
      kind = ""; kind_source = ""; kind_expires = ""; tags_inner = ""
      have_org = 0; have_role = 0; have_location = 0; have_last_touch = 0
      have_kind = 0; have_kind_source = 0; have_kind_expires = 0; have_tags = 0
      state = 0
    }

    # Emit the JSON object for the file just finished (a no-op before the
    # first file, since slug is still empty).
    function emit(   n, parts, tags_json, i, cnt, piece, out) {
      if (slug == "") return

      if (tags_inner == "") {
        tags_json = "[]"
      } else {
        cnt = split(tags_inner, pieces, ",")
        out = ""
        for (i = 1; i <= cnt; i++) {
          piece = pieces[i]
          gsub(/^ +/, "", piece)
          gsub(/ +$/, "", piece)
          if (piece == "") continue
          if (out != "") out = out ","
          out = out "\"" jesc(piece) "\""
        }
        tags_json = "[" out "]"
      }

      printf "{\"%s\": {\"tags\": %s, \"org\": %s, \"role\": %s, \"location\": %s, \"last-touch\": %s, \"kind\": %s, \"kind_source\": %s, \"kind_expires\": %s}}\n", \
        jesc(slug), tags_json, jv(org), jv(role), jv(location), jv(last_touch), jv(kind), jv(kind_source), jv(kind_expires)
    }

    BEGIN { reset() }

    # New file: flush the previous file'"'"'s record, then start fresh.
    FNR == 1 {
      emit()
      reset()
      n = split(FILENAME, parts, "/")
      slug = parts[n]
      sub(/\.md$/, "", slug)
      state = 0
    }

    # Frontmatter delimiters: first '"'"'---'"'"' opens (state 0 -> 1), second
    # closes (state 1 -> 2). Anything after the second delimiter is body
    # text and is ignored, matching extract_frontmatter'"'"'s `c == 2 { exit }`.
    /^---$/ {
      if (state == 0) { state = 1 }
      else if (state == 1) { state = 2 }
      next
    }

    # Frontmatter field lines: first occurrence of each key wins (matches
    # the old `sed ... | head -1`).
    state == 1 {
      if (!have_org && match($0, /^org:[ ]*/)) { org = substr($0, RLENGTH + 1); have_org = 1; next }
      if (!have_role && match($0, /^role:[ ]*/)) { role = substr($0, RLENGTH + 1); have_role = 1; next }
      if (!have_location && match($0, /^location:[ ]*/)) { location = substr($0, RLENGTH + 1); have_location = 1; next }
      if (!have_last_touch && match($0, /^last-touch:[ ]*/)) { last_touch = substr($0, RLENGTH + 1); have_last_touch = 1; next }
      if (!have_kind_source && match($0, /^kind_source:[ ]*/)) { kind_source = substr($0, RLENGTH + 1); have_kind_source = 1; next }
      if (!have_kind_expires && match($0, /^kind_expires:[ ]*/)) { kind_expires = substr($0, RLENGTH + 1); have_kind_expires = 1; next }
      if (!have_kind && match($0, /^kind:[ ]*/)) { kind = substr($0, RLENGTH + 1); have_kind = 1; next }
      if (!have_tags && match($0, /^tags:[ ]*/)) {
        val = substr($0, RLENGTH + 1)
        sub(/^\[/, "", val)
        sub(/\]$/, "", val)
        tags_inner = val
        have_tags = 1
        next
      }
      next
    }

    END { emit() }
  ' "$@" | jq -s 'add' | jq -S '.' > "$INDEX_PATH"
fi

echo "indexed ${count} people → ${INDEX_PATH}"
