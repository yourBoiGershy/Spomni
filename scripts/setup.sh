#!/bin/bash
# setup.sh — the deterministic half of first-run setup (docs/SETUP.md).
#
# Usage:
#   bash scripts/setup.sh --demo            # synthetic demo store, no accounts needed
#   bash scripts/setup.sh [--store <dir>]   # your own store (default: data/store, created if missing)
#   bash scripts/setup.sh --lanes           # also write connectors/sync-scheduler/lanes.tsv for this checkout
#
# What it does, in order (each step prints OK/FAIL/SKIP; nothing here needs
# a human): prerequisite check → npm ci for the query server → create or
# wire the store → safety check on its location → run the store validator →
# (optional) generate lanes.tsv with this checkout's absolute paths → print
# the short list of things only you can do (accounts, TCC grant, Beeper).
# Idempotent: re-run any time.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEMO=0; LANES=0; STORE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --demo) DEMO=1 ;;
    --lanes) LANES=1 ;;
    --store) shift; STORE="${1:-}" ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "FAIL: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

fail=0
ok()   { echo "OK:   $*"; }
bad()  { echo "FAIL: $*"; fail=1; }
skip() { echo "SKIP: $*"; }

# 1. Prerequisites -----------------------------------------------------------
echo "== prerequisites"
[ "$(uname -s)" = "Darwin" ] && ok "macOS" || bad "macOS required (launchd, Beeper Desktop); see docs/SETUP.md §0"
for bin in git jq openssl shasum; do
  command -v "$bin" >/dev/null 2>&1 && ok "$bin" || bad "$bin missing (brew install $bin)"
done
if command -v node >/dev/null 2>&1; then
  v="$(node -v | sed 's/^v//')"; major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
  if [ "$major" -gt 22 ] || { [ "$major" -eq 22 ] && [ "$minor" -ge 6 ]; }; then ok "node $v"
  else bad "node >= 22.6 required for the query server (have $v)"; fi
else bad "node missing (>= 22.6) — https://nodejs.org"; fi
command -v claude >/dev/null 2>&1 && ok "claude (Claude Code CLI)" || bad "claude CLI missing — https://claude.com/claude-code"
command -v ollama >/dev/null 2>&1 && ok "ollama (optional, local embeddings)" || skip "ollama not installed — embeddings degrade gracefully; optional"
[ "$fail" = 0 ] || { echo; echo "Fix the FAIL lines above and re-run."; exit 1; }

# 2. Query server deps -------------------------------------------------------
echo "== query server"
if [ -d packages/query/server/node_modules ]; then ok "packages/query/server/node_modules present"
else (cd packages/query/server && npm ci --silent) && ok "npm ci" || bad "npm ci failed in packages/query/server"; fi

# 3. Store -------------------------------------------------------------------
echo "== store"
if [ "$DEMO" = 1 ]; then
  DEMO_DIR="$HOME/.local/share/spomni/demo-store"
  mkdir -p "$(dirname "$DEMO_DIR")"
  bash packages/core/scripts/demo-store.sh "$DEMO_DIR" --force >/dev/null && ok "demo store at $DEMO_DIR" || bad "demo-store.sh failed"
  ln -sfn "$DEMO_DIR" data/store && ok "data/store -> $DEMO_DIR"
elif [ -n "$STORE" ]; then
  [ -d "$STORE" ] || bash packages/core/scripts/init-store.sh "$STORE" >/dev/null || bad "init-store.sh $STORE"
  abs="$(cd "$STORE" && pwd -P)"
  ln -sfn "$abs" data/store && ok "data/store -> $abs"
else
  if [ -e data/store ]; then ok "data/store already exists ($(cd data/store && pwd -P))"
  else
    echo "  data/store is empty. Clone your private store there, or create a fresh one:"
    echo "    git clone git@github.com:<you>/<your-private-people-store>.git data/store"
    echo "    bash packages/core/scripts/init-store.sh data/store"
    echo "  or try the demo first:  bash scripts/setup.sh --demo"
    skip "no store yet"
  fi
fi
if [ -d data/store ]; then
  bash packages/core/scripts/check-store-location.sh data/store || bad "store location unsafe — see the lines above"
  bash packages/core/scripts/validate-store.sh data/store >/dev/null 2>&1 && ok "validate-store" || bad "validate-store.sh data/store reported problems (run it directly to see them)"
fi

# 4. Lanes -------------------------------------------------------------------
if [ "$LANES" = 1 ]; then
  echo "== scheduler lanes"
  dst="data/connectors/sync-scheduler/lanes.tsv"
  if [ -f "$dst" ]; then skip "$dst exists — not overwriting"
  else
    mkdir -p "$(dirname "$dst")"
    sed "s|<ABS-REPO-ROOT>|$ROOT|g" packages/core/templates/sync-lanes.tsv > "$dst" && ok "wrote $dst (beeper lane, 15 min)"
    echo "  install with: bash packages/connectors/scripts/sync-scheduler.sh install"
  fi
fi

# 5. The human list ----------------------------------------------------------
echo
echo "== done by the machine. Left for you (docs/SETUP.md has the detail):"
case "$ROOT" in
  "$HOME"/Documents/*|"$HOME"/Desktop/*|"$HOME"/Downloads/*)
    echo "  ! This checkout is under ~/Documents|Desktop|Downloads: scheduled syncs will be blocked by macOS"
    echo "    until you grant /bin/bash Full Disk Access (SETUP §1) — or clone somewhere like ~/spomni." ;;
esac
echo "  1. Open a Claude Code session here and approve the 'spomni-query' MCP server."
if [ "$DEMO" = 1 ]; then
  echo "  2. Ask: \"who should I reach out to this week?\"  — everyone in the demo store is fictional."
  echo "  3. When ready for your own data: bash scripts/setup.sh  (then SETUP §2–5)"
else
  echo "  2. /mcp → authenticate Gmail and Google Calendar (first-party connectors)."
  echo "  3. Optional, personal chats: install Beeper Desktop (SETUP §3b)."
  echo "  4. /onboarding-seed — backfill your history and confirm priority tiers."
fi
[ "$fail" = 0 ]
