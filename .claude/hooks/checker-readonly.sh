#!/bin/bash
# checker-readonly.sh — PreToolUse hook for Edit|Write.
# ENFORCES: the *-checker naming contract — checker agents are read-only.
# If the executing agent's type contains "-checker", any Edit/Write is
# blocked with exit 2. Fails OPEN when the agent type cannot be determined.
# Bash 3.2 portable.

INPUT=$(cat 2>/dev/null) || exit 0

AGENT=""
if command -v jq >/dev/null 2>&1; then
  AGENT=$(printf '%s' "$INPUT" | jq -r '.agent_type // .subagent_type // empty' 2>/dev/null)
fi
[ -z "$AGENT" ] && AGENT="${CLAUDE_AGENT_TYPE:-}"

case "$AGENT" in
  *-checker*)
    echo "BLOCKED: $AGENT is a read-only checker agent — checkers never write. Report findings instead." >&2
    exit 2
    ;;
esac

exit 0
