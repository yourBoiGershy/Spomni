#!/bin/bash
# orchestrator-edit-guard.sh — PreToolUse hook for Edit|Write.
# ENFORCES: "the main conversation orchestrates; it never edits production
# code." For this project, production code = the assistant's machinery:
# everything under packages/ (contracts, templates, skills, scripts,
# fixtures — package.md manifests included) plus the harness's own skills,
# agents, scripts, and hooks. When the MAIN conversation (empty agent type)
# tries to Edit/Write under a protected prefix, the write is blocked with
# exit 2. docs/, data/, root markdown, and .claude/rules|context|settings
# stay orchestrator-editable for planning work.
# Fails OPEN on parse errors. Bash 3.2 portable.

# Space-separated, repo-relative, trailing slash. Override via env if needed.
PROTECTED_PREFIXES="${HARNESS_PROTECTED_PREFIXES:-.claude/skills/ .claude/agents/ .claude/scripts/ .claude/hooks/ packages/}"

INPUT=$(cat 2>/dev/null) || exit 0

AGENT=""
FILE=""
if command -v jq >/dev/null 2>&1; then
  AGENT=$(printf '%s' "$INPUT" | jq -r '.agent_type // .subagent_type // empty' 2>/dev/null)
  FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
else
  FILE=$(printf '%s' "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi
[ -z "$AGENT" ] && AGENT="${CLAUDE_AGENT_TYPE:-}"

# Subagents are governed by their own tool grants + the checker-readonly hook.
[ -n "$AGENT" ] && exit 0
[ -z "$FILE" ] && exit 0

# Normalize to a repo-relative path where possible.
REL="$FILE"
ROOT="${CLAUDE_PROJECT_DIR:-}"
if [ -n "$ROOT" ]; then
  case "$FILE" in
    "$ROOT"/*) REL="${FILE#"$ROOT"/}" ;;
  esac
fi

for P in $PROTECTED_PREFIXES; do
  case "$REL" in
    "$P"*)
      echo "BLOCKED: main conversation must not edit assistant machinery ($REL). Spawn a dev-worker with a scoped brief instead (see .claude/rules/orchestration.md)." >&2
      exit 2
      ;;
  esac
done

exit 0
