#!/usr/bin/env bash
# demo-store.sh — materialize a synthetic demo store a stranger can point the
# query server and skills at, with no real account or private data required.
#
# Usage: demo-store.sh <dest-dir> [--force]
#
# Copies packages/core/fixtures/store/ (30 synthetic people, 47 interactions,
# wakeups; no real relationships, no real accounts) into <dest-dir>, ensures
# inbox/ exists, builds index.json + stats.json, validates the result, and
# writes <dest-dir>/DEMO-STORE.md marking it as synthetic/regeneratable.
#
# Refuses (exit 2, "FAIL:") to write into a non-empty <dest-dir> unless
# --force is passed.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_STORE="$CORE_DIR/fixtures/store"

usage() {
  echo "Usage: demo-store.sh <dest-dir> [--force]" >&2
}

dest=""
force=0

for arg in "$@"; do
  case "$arg" in
    --force)
      force=1
      ;;
    -*)
      echo "FAIL: unknown option: $arg" >&2
      usage
      exit 2
      ;;
    *)
      if [ -n "$dest" ]; then
        echo "FAIL: unexpected extra argument: $arg" >&2
        usage
        exit 2
      fi
      dest="$arg"
      ;;
  esac
done

if [ -z "$dest" ]; then
  echo "FAIL: missing required <dest-dir> argument" >&2
  usage
  exit 2
fi

if [ ! -d "$FIXTURE_STORE" ]; then
  echo "FAIL: demo fixture store not found at $FIXTURE_STORE" >&2
  exit 2
fi

if [ -e "$dest" ] && [ ! -d "$dest" ]; then
  echo "FAIL: $dest exists and is not a directory" >&2
  exit 2
fi

if [ -d "$dest" ]; then
  # non-empty check (portable: ls -A the dir)
  if [ -n "$(ls -A "$dest" 2>/dev/null)" ] && [ "$force" -ne 1 ]; then
    echo "FAIL: $dest already exists and is non-empty (use --force to overwrite)" >&2
    exit 2
  fi
fi

mkdir -p "$dest"

# Resolve dest to an absolute path (bash 3.2 portable: no readlink -f).
abs_dest="$(cd "$dest" && pwd -P)"

cp -R "$FIXTURE_STORE"/. "$abs_dest"/

mkdir -p "$abs_dest/inbox"

"$SCRIPT_DIR/build-index.sh" "$abs_dest"
"$SCRIPT_DIR/build-stats.sh" "$abs_dest"

if ! "$SCRIPT_DIR/validate-store.sh" "$abs_dest"; then
  echo "FAIL: validate-store.sh reported problems in the freshly-built demo store at $abs_dest" >&2
  exit 1
fi

people_count="$(ls "$abs_dest"/people/*.md 2>/dev/null | wc -l | tr -d ' ')"
interactions_count="$(ls "$abs_dest"/interactions/*.md 2>/dev/null | wc -l | tr -d ' ')"

cat > "$abs_dest/DEMO-STORE.md" <<EOF
# Demo store

Everyone in this store is fictional — synthetic people, synthetic
interactions, nothing from a real account or a real relationship.

Safe to delete at any time; regenerate it with:
\`bash packages/core/scripts/demo-store.sh <dest-dir> --force\`
EOF

echo "OK: demo store at ${abs_dest} (${people_count} synthetic people, ${interactions_count} interactions)"
echo "Next:"
echo "  ln -sfn ${abs_dest} data/store          # point the repo at it (data/ is gitignored)"
echo "  open a Claude Code session here and ask: \"who should I reach out to this week?\""
echo ""
echo "Everyone in this store is fictional. Replace it with your own store when ready: docs/SETUP.md §2."
