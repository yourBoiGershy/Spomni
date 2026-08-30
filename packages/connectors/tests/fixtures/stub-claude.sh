#!/bin/bash
# stub-claude.sh — offline stand-in for the `claude` CLI, used by
# run-scheduler-tests.sh to exercise packages/connectors/scripts/mcp-lane-tick.sh
# (the "tick" and "preflight" subcommands) without ever invoking a real
# claude session.
#
# Argv recording: if $STUB_CLAUDE_ARGV_FILE is set, the full argv this stub
# was invoked with is appended to that file, one argument per line, with a
# blank line as a terminator between invocations (mcp-lane-tick.sh's
# preflight path may invoke the stub more than once).
#
# Behavior is selected by $STUB_CLAUDE_MODE:
#   ok            print "sweep-ok pages=1 inline-spilled=0", exit 0
#   nosummary     print "hello", exit 0
#   exit7         exit 7 (no output)
#   sleep         sleep 30 (used to exercise the watchdog's timeout path)
#   tools-full    print all five required MCP tool names, one per line, exit 0
#   tools-missing print all required tool names except
#                 mcp__claude_ai_Google_Calendar__list_events and
#                 mcp__claude_ai_Gmail__get_thread, exit 0
#
# bash 3.2 portable — no associative arrays, no ${var,,}.

set -u

if [ -n "${STUB_CLAUDE_ARGV_FILE:-}" ]; then
	for arg in "$@"; do
		printf '%s\n' "$arg" >> "$STUB_CLAUDE_ARGV_FILE"
	done
	printf '\n' >> "$STUB_CLAUDE_ARGV_FILE"
fi

MODE="${STUB_CLAUDE_MODE:-ok}"

case "$MODE" in
	ok)
		echo "sweep-ok pages=1 inline-spilled=0"
		exit 0
		;;
	nosummary)
		echo "hello"
		exit 0
		;;
	exit7)
		exit 7
		;;
	sleep)
		sleep 30
		exit 0
		;;
	tools-full)
		echo "mcp__claude_ai_Gmail__search_threads"
		echo "mcp__claude_ai_Gmail__get_thread"
		echo "mcp__claude_ai_Gmail__get_message"
		echo "mcp__claude_ai_Google_Calendar__list_calendars"
		echo "mcp__claude_ai_Google_Calendar__list_events"
		exit 0
		;;
	tools-missing)
		echo "mcp__claude_ai_Gmail__search_threads"
		echo "mcp__claude_ai_Gmail__get_message"
		echo "mcp__claude_ai_Google_Calendar__list_calendars"
		exit 0
		;;
	*)
		echo "stub-claude: unknown STUB_CLAUDE_MODE '$MODE'" >&2
		exit 9
		;;
esac
