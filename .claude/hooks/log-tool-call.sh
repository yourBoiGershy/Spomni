#!/bin/bash
# log-tool-call.sh — PostToolUse hook for Bash.
# RECORDS: every Bash tool call as one JSONL line in
# .claude/logs/tool-calls.jsonl (timestamp, agent type, command). Telemetry
# only — never blocks. Self-rotates at 10k lines. Always exits 0.
# Bash 3.2 portable.

INPUT=$(cat 2>/dev/null) || exit 0
[ -z "$INPUT" ] && exit 0

LOGDIR="${CLAUDE_PROJECT_DIR:-.}/.claude/logs"
LOGFILE="$LOGDIR/tool-calls.jsonl"
mkdir -p "$LOGDIR" 2>/dev/null || exit 0

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$INPUT" | jq -c --arg ts "$TS" \
    '{ts:$ts, agent:((.agent_type // .subagent_type // "") | if . == "" then "main" else . end), command:(.tool_input.command // "" | .[0:500])}' \
    >> "$LOGFILE" 2>/dev/null
else
  printf '{"ts":"%s","raw":"unparsed (jq missing)"}\n' "$TS" >> "$LOGFILE" 2>/dev/null
fi

LINES=$(wc -l < "$LOGFILE" 2>/dev/null | tr -d ' ')
if [ -n "$LINES" ] && [ "$LINES" -gt 10000 ] 2>/dev/null; then
  tail -5000 "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null && mv "$LOGFILE.tmp" "$LOGFILE"
fi

exit 0
