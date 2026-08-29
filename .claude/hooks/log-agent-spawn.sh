#!/bin/bash
# log-agent-spawn.sh — PostToolUse hook for Agent/Task.
# RECORDS: every subagent spawn as one JSONL line in
# .claude/logs/agent-spawns.jsonl — the delegation audit trail (who was
# spawned, with what description). Self-rotates at 10k lines. Always exits 0.
# Bash 3.2 portable.

INPUT=$(cat 2>/dev/null) || exit 0
[ -z "$INPUT" ] && exit 0

LOGDIR="${CLAUDE_PROJECT_DIR:-.}/.claude/logs"
LOGFILE="$LOGDIR/agent-spawns.jsonl"
mkdir -p "$LOGDIR" 2>/dev/null || exit 0

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$INPUT" | jq -c --arg ts "$TS" \
    '{ts:$ts, agent_type:(.tool_input.subagent_type // "general"), description:(.tool_input.description // ""), session:(.session_id // "")}' \
    >> "$LOGFILE" 2>/dev/null
else
  printf '{"ts":"%s","raw":"unparsed (jq missing)"}\n' "$TS" >> "$LOGFILE" 2>/dev/null
fi

# rotate: keep the newest 5k lines once we cross 10k
LINES=$(wc -l < "$LOGFILE" 2>/dev/null | tr -d ' ')
if [ -n "$LINES" ] && [ "$LINES" -gt 10000 ] 2>/dev/null; then
  tail -5000 "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null && mv "$LOGFILE.tmp" "$LOGFILE"
fi

exit 0
