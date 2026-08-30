#!/bin/bash
# mcp-lane-tick.sh — headless-session wrapper that a sync-scheduler lane row's
# command points at (plan 28 D2), so gmail/calendar MCP sweeps can run under
# launchd via `claude -p`.
#
# Usage:
#   mcp-lane-tick.sh tick \
#     --claude-bin <abs-path> \            # required; launchd PATH won't find claude
#     --prompt "<slash-command line>" \    # required, e.g. "/gmail-sweep pages=4"
#     --allowed-tools "<csv>" \            # required; pinned per lane
#     [--max-turns N]       \              # default 50; passed to claude -p
#     [--timeout-seconds N] \              # default 900; wrapper-enforced watchdog
#     [--expect <regex>]                   # default 'sweep-ok'; summary-line gate
#
#   mcp-lane-tick.sh preflight \
#     --claude-bin <abs-path> \            # required
#     --lane gmail|calendar                # required; selects tool pin + required names
#
# tick: execs `"$CLAUDE_BIN" -p "$PROMPT" --permission-mode acceptEdits
# --allowedTools <csv> --max-turns N` in the background with combined
# stdout+stderr captured to a temp file. A watchdog subshell enforces
# --timeout-seconds: SIGTERM, then SIGKILL after a 15s grace (bash 3.2
# portable — background child + sleep/kill; macOS ships no GNU `timeout`).
#
# On completion, success is gated on the sweep's own summary line: the
# captured output must match --expect (the sweeps end with `sweep-ok ...`
# per their SKILLs) — a session that chatted instead of sweeping is a
# failure, not a success.
#
# tick exit codes, each with a distinct log line so silence is impossible:
#   0  tick-ok                        claude exited 0 AND --expect matched
#   3  tick-fail reason=timeout       watchdog killed the process
#   4  tick-fail reason=no-summary    claude exited 0 but no summary line
#   2  argument error + usage         missing required flag / unknown flag
#   N  tick-fail reason=exit=<n>      claude's own nonzero exit, propagated
#      verbatim (including if claude itself happens to exit 2/3/4 — the log
#      line disambiguates from the wrapper's own codes; never remapped)
#
# preflight: a one-shot connector-availability probe run before a lane is
# enabled (plan 28 D2), so a missing/renamed first-party MCP tool is caught
# cheaply rather than as a failed scheduled tick. Runs a minimal `claude -p`
# probe (--max-turns 4, same allowed-tools pinning as the lane) whose prompt
# asks the session to enumerate available tools and print only the ones
# matching the lane's MCP prefix, one per line, nothing else. Reuses the
# tick path's watchdog with a fixed 120s timeout so a hung probe can't wedge.
# The wrapper then `grep -F`s the lane's required tool names out of the
# captured output.
#
# Required tool names per lane (inline, per D2):
#   gmail    — mcp__claude_ai_Gmail__search_threads,
#              mcp__claude_ai_Gmail__get_thread, mcp__claude_ai_Gmail__get_message
#   calendar — mcp__claude_ai_Google_Calendar__list_calendars,
#              mcp__claude_ai_Google_Calendar__list_events
#
# preflight exit codes:
#   0  preflight-ok matched=<names>    all required tools found
#   2  preflight-fail missing=<names>  one or more required tools absent
#   2  argument error + usage          unknown/missing --lane, missing flags
#      (exit 2 doubles as arg-error and preflight-fail; the log line
#      disambiguates — never remapped, per D2)
#   3  preflight-fail reason=timeout   watchdog killed the probe (120s)
#   N  preflight-fail reason=exit=<n>  claude's own nonzero exit, propagated
#
# bash 3.2 (macOS default) / launchd's minimal PATH=/usr/bin:/bin:/usr/sbin:/sbin
# — no associative arrays, no mapfile, no ${var,,}, no GNU-only flags, no
# dependency beyond /usr/bin (no jq). Writes no files of its own (temp files
# are scratch-only, cleaned up on exit) — the scheduler owns state/logs.
#
# `case "$1"` dispatch at the bottom: `tick` and `preflight`.

set -u

SCRIPT_NAME="$(basename "$0")"

usage() {
	echo "Usage: $SCRIPT_NAME tick --claude-bin <abs-path> --prompt <prompt> --allowed-tools <csv> [--max-turns N] [--timeout-seconds N] [--expect <regex>]" >&2
	echo "       $SCRIPT_NAME preflight --claude-bin <abs-path> --lane gmail|calendar" >&2
	exit 2
}

log() {
	# $1 = message
	echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) mcp-lane-tick: $1" >&2
}

# ---------------------------------------------------------------------------
# run_claude_watchdog <claude_bin> <prompt> <allowed_tools> <max_turns>
#   <timeout_seconds> <out_file> — runs claude in the background, captures
# combined stdout+stderr to <out_file>, and enforces <timeout_seconds> via a
# watchdog subshell (SIGTERM, 15s grace, SIGKILL). Sets RUN_EXIT (claude's
# exit code, meaningless if timed out) and RUN_TIMED_OUT (1 if the watchdog
# fired, else 0). Shared by both the tick and preflight subcommands.
# ---------------------------------------------------------------------------
run_claude_watchdog() {
	run_claude_bin="$1"
	run_prompt="$2"
	run_allowed_tools="$3"
	run_max_turns="$4"
	run_timeout_seconds="$5"
	run_out_file="$6"

	run_killed_flag="$(mktemp)"
	rm -f "$run_killed_flag"

	"$run_claude_bin" -p "$run_prompt" --permission-mode acceptEdits --allowedTools "$run_allowed_tools" --max-turns "$run_max_turns" >"$run_out_file" 2>&1 &
	run_claude_pid=$!

	(
		trap 'kill "$run_wait_pid" 2>/dev/null; exit' TERM

		sleep "$run_timeout_seconds" &
		run_wait_pid=$!
		wait "$run_wait_pid"

		if kill -0 "$run_claude_pid" 2>/dev/null; then
			: > "$run_killed_flag"
			kill -TERM "$run_claude_pid" 2>/dev/null

			sleep 15 &
			run_wait_pid=$!
			wait "$run_wait_pid"

			kill -KILL "$run_claude_pid" 2>/dev/null
		fi
	) >/dev/null 2>&1 &
	run_watchdog_pid=$!

	wait "$run_claude_pid"
	RUN_EXIT=$?

	# Watchdog no longer needed once claude has exited; stop it quietly.
	kill "$run_watchdog_pid" 2>/dev/null
	wait "$run_watchdog_pid" 2>/dev/null

	if [ -f "$run_killed_flag" ]; then
		RUN_TIMED_OUT=1
	else
		RUN_TIMED_OUT=0
	fi
	rm -f "$run_killed_flag"
}

cmd_tick() {
	CLAUDE_BIN=""
	PROMPT=""
	ALLOWED_TOOLS=""
	MAX_TURNS=50
	TIMEOUT_SECONDS=900
	EXPECT='sweep-ok'

	while [ $# -gt 0 ]; do
		case "$1" in
			--claude-bin)
				[ $# -ge 2 ] || usage
				CLAUDE_BIN="$2"
				shift 2
				;;
			--prompt)
				[ $# -ge 2 ] || usage
				PROMPT="$2"
				shift 2
				;;
			--allowed-tools)
				[ $# -ge 2 ] || usage
				ALLOWED_TOOLS="$2"
				shift 2
				;;
			--max-turns)
				[ $# -ge 2 ] || usage
				MAX_TURNS="$2"
				shift 2
				;;
			--timeout-seconds)
				[ $# -ge 2 ] || usage
				TIMEOUT_SECONDS="$2"
				shift 2
				;;
			--expect)
				[ $# -ge 2 ] || usage
				EXPECT="$2"
				shift 2
				;;
			*)
				usage
				;;
		esac
	done

	[ -n "$CLAUDE_BIN" ] || usage
	[ -n "$PROMPT" ] || usage
	[ -n "$ALLOWED_TOOLS" ] || usage

	OUT_FILE="$(mktemp)"
	trap 'rm -f "$OUT_FILE"' EXIT

	run_claude_watchdog "$CLAUDE_BIN" "$PROMPT" "$ALLOWED_TOOLS" "$MAX_TURNS" "$TIMEOUT_SECONDS" "$OUT_FILE"

	if [ "$RUN_TIMED_OUT" -eq 1 ]; then
		log "tick-fail reason=timeout"
		exit 3
	fi

	if [ "$RUN_EXIT" -ne 0 ]; then
		log "tick-fail reason=exit=${RUN_EXIT}"
		exit "$RUN_EXIT"
	fi

	if grep -Eq "$EXPECT" "$OUT_FILE"; then
		log "tick-ok"
		exit 0
	fi

	log "tick-fail reason=no-summary"
	exit 4
}

cmd_preflight() {
	CLAUDE_BIN=""
	LANE=""

	while [ $# -gt 0 ]; do
		case "$1" in
			--claude-bin)
				[ $# -ge 2 ] || usage
				CLAUDE_BIN="$2"
				shift 2
				;;
			--lane)
				[ $# -ge 2 ] || usage
				LANE="$2"
				shift 2
				;;
			*)
				usage
				;;
		esac
	done

	[ -n "$CLAUDE_BIN" ] || usage
	[ -n "$LANE" ] || usage

	case "$LANE" in
		gmail)
			TOOL_PREFIX="mcp__claude_ai_Gmail__"
			ALLOWED_TOOLS="${TOOL_PREFIX}*"
			REQUIRED_TOOLS="${TOOL_PREFIX}search_threads ${TOOL_PREFIX}get_thread ${TOOL_PREFIX}get_message"
			;;
		calendar)
			TOOL_PREFIX="mcp__claude_ai_Google_Calendar__"
			ALLOWED_TOOLS="${TOOL_PREFIX}*"
			REQUIRED_TOOLS="${TOOL_PREFIX}list_calendars ${TOOL_PREFIX}list_events"
			;;
		*)
			usage
			;;
	esac

	PROMPT="Enumerate the tools available to you in this session. Print only the ones whose name starts with '${TOOL_PREFIX}', one per line, and nothing else."

	OUT_FILE="$(mktemp)"
	trap 'rm -f "$OUT_FILE"' EXIT

	run_claude_watchdog "$CLAUDE_BIN" "$PROMPT" "$ALLOWED_TOOLS" 4 120 "$OUT_FILE"

	if [ "$RUN_TIMED_OUT" -eq 1 ]; then
		log "preflight-fail reason=timeout"
		exit 3
	fi

	if [ "$RUN_EXIT" -ne 0 ]; then
		log "preflight-fail reason=exit=${RUN_EXIT}"
		exit "$RUN_EXIT"
	fi

	MISSING=""
	MATCHED=""
	for tool in $REQUIRED_TOOLS; do
		if grep -Fq "$tool" "$OUT_FILE"; then
			MATCHED="$MATCHED $tool"
		else
			MISSING="$MISSING $tool"
		fi
	done

	if [ -n "$MISSING" ]; then
		log "preflight-fail missing=${MISSING# }"
		exit 2
	fi

	log "preflight-ok matched=${MATCHED# }"
	exit 0
}

[ $# -ge 1 ] || usage
SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
	tick)
		cmd_tick "$@"
		;;
	preflight)
		cmd_preflight "$@"
		;;
	*)
		usage
		;;
esac
