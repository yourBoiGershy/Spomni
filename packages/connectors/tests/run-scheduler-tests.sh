#!/usr/bin/env bash
# packages/connectors/tests/run-scheduler-tests.sh
#
# Offline test suite for the plan-19 sync scheduler
# (packages/connectors/scripts/sync-lib.sh +
# packages/connectors/scripts/sync-scheduler.sh), per
# docs/plans/2026-08-29-19-sync-scheduler.md ("Pinned lib API", "CLI",
# "Tests"). Covers:
#
#   1. Config parsing: valid file (comments/blanks skipped), each malformed
#      row class (field count, lane regex, interval < 60 / non-integer,
#      enabled literal, duplicate lane) -> exit 1 + specific stderr reason,
#      missing config -> exit 1.
#   2. sync_lane_get: found row, unknown lane (exit 2), invalid config
#      (exit 1).
#   3. State: NEVER_RUN before any write, write/read round-trip.
#   4. Log append + rotation past the 512000-byte cap -> .log.1.
#   5. sync_run_lane against a stub command: records state, appends output,
#      propagates the command's exit code; skip-disabled path (exit 0, state
#      untouched); unknown lane (exit 2).
#   6. CLI install --dry-run: enabled lane rendered with correct label/
#      interval/scheduler-path/data-dir; disabled lane excluded; nothing
#      written to disk, no launchctl invoked.
#   7. CLI uninstall --dry-run: prints the actions it would take, performs
#      none of them.
#   8. CLI status: one row per configured lane (including disabled and
#      never-run/not-installed), malformed config -> exit 1.
#
# No launchctl invocations anywhere in this suite: install/uninstall are only
# ever exercised with --dry-run, and every lane name used here is a unique,
# never-installed synthetic name so sync-scheduler.sh's own
# `[ -f "$dest" ]` short-circuit in is_installed() never reaches the
# launchctl call (status coverage) even without --dry-run.
#
# bash 3.2 portable (no associative arrays, no mapfile, no ${var,,}) — must
# run under macOS's stock /bin/bash. Same pass/fail/SUMMARY style as
# run-beeper-capture-tests.sh. Never edits sync-lib.sh, sync-scheduler.sh, or
# the plist template — only reads them, plus test-local mktemp fixtures
# created here.

set -u

# --- resolve repo root relative to this script, not the caller's cwd ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

LIB="$REPO_ROOT/packages/connectors/scripts/sync-lib.sh"
CLI="$REPO_ROOT/packages/connectors/scripts/sync-scheduler.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  echo "PASS: $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "FAIL: $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_eq() {
  # $1=description $2=actual $3=expected
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1 (expected [$3], got [$2])"
  fi
}

assert_contains() {
  # $1=description $2=haystack $3=needle
  case "$2" in
    *"$3"*)
      pass "$1"
      ;;
    *)
      fail "$1 (expected to find [$3] in: $2)"
      ;;
  esac
}

assert_not_contains() {
  # $1=description $2=haystack $3=needle
  case "$2" in
    *"$3"*)
      fail "$1 (did not expect to find [$3] in: $2)"
      ;;
    *)
      pass "$1"
      ;;
  esac
}

if [ ! -f "$LIB" ]; then
  echo "SKIP: $LIB not found — cannot run sync scheduler tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, sync-lib.sh missing"
  exit 1
fi

if [ ! -x "$CLI" ]; then
  echo "SKIP: $CLI not found/executable — cannot run sync scheduler tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, sync-scheduler.sh missing"
  exit 1
fi

# shellcheck disable=SC1090
source "$LIB"

# --- throwaway sandbox, cleaned up on exit ---
SANDBOX="$(mktemp -d)"
cleanup() {
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

# Unique-ish lane name prefix so status/install/uninstall coverage never
# collides with any real launchd agent on the machine running this suite.
LANE_NS="zzscheduler$$"

# =============================================================================
# 1. Config parsing — valid file, each malformed row class, missing file
# =============================================================================

cfg_dir="$SANDBOX/config"
mkdir -p "$cfg_dir"

valid_cfg="$cfg_dir/valid.tsv"
cat > "$valid_cfg" <<EOF
# a comment line, should be skipped

${LANE_NS}-a	60	true	/bin/echo lane-a
${LANE_NS}-b	120	false	/bin/echo lane-b
EOF

valid_out="$(sync_lanes_list "$valid_cfg")"
valid_rc=$?
assert_eq "config: valid file parses (rc=0)" "$valid_rc" "0"
assert_eq "config: valid file yields 2 rows" "$(printf '%s\n' "$valid_out" | grep -c .)" "2"
assert_contains "config: comments/blanks are skipped, row A present" "$valid_out" "${LANE_NS}-a"
assert_contains "config: comments/blanks are skipped, row B present" "$valid_out" "${LANE_NS}-b"

missing_cfg="$cfg_dir/does-not-exist.tsv"
missing_err="$(sync_lanes_list "$missing_cfg" 2>&1 >/dev/null)"
missing_out="$(sync_lanes_list "$missing_cfg" 2>/dev/null)"
missing_rc=$?
assert_eq "config: missing file -> exit 1" "$missing_rc" "1"
assert_eq "config: missing file -> no stdout" "$missing_out" ""
assert_contains "config: missing file -> stderr note" "$missing_err" "no such config file"

bad_field_count="$cfg_dir/bad-field-count.tsv"
printf '%s\t%s\t%s\n' "${LANE_NS}-c" "60" "true" > "$bad_field_count"
bfc_err="$(sync_lanes_list "$bad_field_count" 2>&1 >/dev/null)"
bfc_out="$(sync_lanes_list "$bad_field_count" 2>/dev/null)"
bfc_rc=$?
assert_eq "config: malformed row (field count) -> exit 1" "$bfc_rc" "1"
assert_eq "config: malformed row (field count) -> no stdout" "$bfc_out" ""
assert_contains "config: malformed row (field count) -> specific reason" "$bfc_err" "expected 4 tab-separated fields"

bad_lane_regex="$cfg_dir/bad-lane-regex.tsv"
printf 'Bad_Lane\t60\ttrue\t/bin/echo hi\n' > "$bad_lane_regex"
blr_err="$(sync_lanes_list "$bad_lane_regex" 2>&1 >/dev/null)"
blr_out="$(sync_lanes_list "$bad_lane_regex" 2>/dev/null)"
blr_rc=$?
assert_eq "config: malformed row (lane regex) -> exit 1" "$blr_rc" "1"
assert_eq "config: malformed row (lane regex) -> no stdout" "$blr_out" ""
assert_contains "config: malformed row (lane regex) -> specific reason" "$blr_err" "lane must match"

bad_interval_low="$cfg_dir/bad-interval-low.tsv"
printf '%s\t59\ttrue\t/bin/echo hi\n' "${LANE_NS}-d" > "$bad_interval_low"
bil_err="$(sync_lanes_list "$bad_interval_low" 2>&1 >/dev/null)"
bil_rc=$?
assert_eq "config: malformed row (interval < 60) -> exit 1" "$bil_rc" "1"
assert_contains "config: malformed row (interval < 60) -> specific reason" "$bil_err" "interval_seconds must be an integer >= 60"

bad_interval_nonint="$cfg_dir/bad-interval-nonint.tsv"
printf '%s\tabc\ttrue\t/bin/echo hi\n' "${LANE_NS}-e" > "$bad_interval_nonint"
bin_err="$(sync_lanes_list "$bad_interval_nonint" 2>&1 >/dev/null)"
bin_rc=$?
assert_eq "config: malformed row (interval non-integer) -> exit 1" "$bin_rc" "1"
assert_contains "config: malformed row (interval non-integer) -> specific reason" "$bin_err" "interval_seconds must be an integer >= 60"

bad_enabled="$cfg_dir/bad-enabled.tsv"
printf '%s\t60\tyes\t/bin/echo hi\n' "${LANE_NS}-f" > "$bad_enabled"
be_err="$(sync_lanes_list "$bad_enabled" 2>&1 >/dev/null)"
be_rc=$?
assert_eq "config: malformed row (enabled literal) -> exit 1" "$be_rc" "1"
assert_contains "config: malformed row (enabled literal) -> specific reason" "$be_err" "enabled must be true|false"

dup_lane="$cfg_dir/dup-lane.tsv"
printf '%s\t60\ttrue\t/bin/echo one\n%s\t120\tfalse\t/bin/echo two\n' "${LANE_NS}-g" "${LANE_NS}-g" > "$dup_lane"
dl_err="$(sync_lanes_list "$dup_lane" 2>&1 >/dev/null)"
dl_rc=$?
assert_eq "config: malformed row (duplicate lane) -> exit 1" "$dl_rc" "1"
assert_contains "config: malformed row (duplicate lane) -> specific reason" "$dl_err" "duplicate lane"

# =============================================================================
# 2. sync_lane_get — found / unknown / invalid config
# =============================================================================

get_found_out="$(sync_lane_get "$valid_cfg" "${LANE_NS}-a")"
get_found_rc=$?
assert_eq "sync_lane_get: known lane -> exit 0" "$get_found_rc" "0"
assert_contains "sync_lane_get: known lane -> row printed" "$get_found_out" "${LANE_NS}-a"

sync_lane_get "$valid_cfg" "${LANE_NS}-does-not-exist" >/dev/null 2>&1
get_unknown_rc=$?
assert_eq "sync_lane_get: unknown lane -> exit 2" "$get_unknown_rc" "2"

sync_lane_get "$bad_field_count" "${LANE_NS}-c" >/dev/null 2>&1
get_invalid_rc=$?
assert_eq "sync_lane_get: invalid config -> exit 1" "$get_invalid_rc" "1"

# =============================================================================
# 3. State — NEVER_RUN, write/read round-trip
# =============================================================================

state_data_dir="$SANDBOX/state-data"
mkdir -p "$state_data_dir"

never_run_out="$(sync_state_read "$state_data_dir" "${LANE_NS}-state")"
never_run_rc=$?
assert_eq "state: unwritten lane reads NEVER_RUN" "$never_run_out" "NEVER_RUN"
assert_eq "state: unwritten lane read always exits 0" "$never_run_rc" "0"

sync_state_write "$state_data_dir" "${LANE_NS}-state" "2026-08-29T10:00:00Z" "2026-08-29T10:00:05Z" "0"
state_rt_out="$(sync_state_read "$state_data_dir" "${LANE_NS}-state")"
assert_eq "state: write/read round-trip" "$state_rt_out" "$(printf '2026-08-29T10:00:00Z\t2026-08-29T10:00:05Z\t0')"

# =============================================================================
# 4. Log append + rotation past the 512000-byte cap
# =============================================================================

log_data_dir="$SANDBOX/log-data"
mkdir -p "$log_data_dir/connectors/sync-scheduler/logs"
log_lane="${LANE_NS}-log"
log_file="$(sync_log_file "$log_data_dir" "$log_lane")"

# Seed a log file already over the rotation cap.
python3 -c "
import sys
with open(sys.argv[1], 'wb') as f:
    f.write(b'x' * 520000)
" "$log_file" 2>/dev/null || {
  # No python3 available: fall back to yes/head (portable, slower).
  yes "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" | head -c 520000 > "$log_file"
}

pre_size="$(wc -c < "$log_file" | tr -d '[:space:]')"

sync_log_append "$log_data_dir" "$log_lane" "post-rotation-marker"

rotated_file="${log_file}.1"
if [ -f "$rotated_file" ]; then
  pass "log rotation: .log.1 created once over the cap"
else
  fail "log rotation: expected $rotated_file to exist"
fi

rotated_size="$(wc -c < "$rotated_file" 2>/dev/null | tr -d '[:space:]')"
assert_eq "log rotation: .log.1 preserves the pre-rotation content size" "$rotated_size" "$pre_size"

new_log_content="$(cat "$log_file" 2>/dev/null)"
assert_contains "log rotation: fresh .log contains only the new message" "$new_log_content" "post-rotation-marker"
new_log_lines="$(grep -c . "$log_file" 2>/dev/null)"
assert_eq "log rotation: fresh .log has exactly one line after rotation" "$new_log_lines" "1"

# =============================================================================
# 5. sync_run_lane — stub command, skip-disabled, unknown lane
# =============================================================================

run_data_dir="$SANDBOX/run-data"
mkdir -p "$run_data_dir"
run_cfg="$SANDBOX/run-config.tsv"

enabled_lane="${LANE_NS}-run-enabled"
disabled_lane="${LANE_NS}-run-disabled"

cat > "$run_cfg" <<EOF
${enabled_lane}	60	true	/bin/echo stub-output-marker; exit 7
${disabled_lane}	60	false	/bin/echo should-not-run
EOF

sync_run_lane "$run_cfg" "$run_data_dir" "$enabled_lane"
run_exit=$?
assert_eq "sync_run_lane: propagates the command's exit code" "$run_exit" "7"

run_state="$(sync_state_read "$run_data_dir" "$enabled_lane")"
assert_not_contains "sync_run_lane: state recorded (no longer NEVER_RUN)" "$run_state" "NEVER_RUN"
run_state_exit="$(printf '%s' "$run_state" | awk -F'\t' '{print $3}')"
assert_eq "sync_run_lane: recorded state's exit code matches" "$run_state_exit" "7"

run_log_content="$(cat "$(sync_log_file "$run_data_dir" "$enabled_lane")" 2>/dev/null)"
assert_contains "sync_run_lane: log contains run-start" "$run_log_content" "run-start"
assert_contains "sync_run_lane: log contains the command's stdout" "$run_log_content" "stub-output-marker"
assert_contains "sync_run_lane: log contains run-end with the exit code" "$run_log_content" "run-end exit=7"

sync_run_lane "$run_cfg" "$run_data_dir" "$disabled_lane"
skip_exit=$?
assert_eq "sync_run_lane: disabled lane exits 0" "$skip_exit" "0"

skip_state="$(sync_state_read "$run_data_dir" "$disabled_lane")"
assert_eq "sync_run_lane: disabled lane never writes state" "$skip_state" "NEVER_RUN"

skip_log_content="$(cat "$(sync_log_file "$run_data_dir" "$disabled_lane")" 2>/dev/null)"
assert_contains "sync_run_lane: disabled lane logs skip-disabled" "$skip_log_content" "skip-disabled"

sync_run_lane "$run_cfg" "$run_data_dir" "${LANE_NS}-run-unknown" >/dev/null 2>&1
unknown_exit=$?
assert_eq "sync_run_lane: unknown lane exits 2" "$unknown_exit" "2"

# =============================================================================
# 6. CLI install --dry-run — rendering, disabled exclusion, no side effects
# =============================================================================

cli_data_dir="$SANDBOX/cli-data"
mkdir -p "$cli_data_dir"
cli_cfg="$(sync_config_path "$cli_data_dir")"
mkdir -p "$(dirname "$cli_cfg")"

install_enabled_lane="${LANE_NS}-install-enabled"
install_disabled_lane="${LANE_NS}-install-disabled"

cat > "$cli_cfg" <<EOF
${install_enabled_lane}	300	true	/bin/echo install-enabled
${install_disabled_lane}	600	false	/bin/echo install-disabled
EOF

install_out="$("$CLI" install --dry-run --data-dir "$cli_data_dir" 2>&1)"
install_rc=$?
assert_eq "install --dry-run: exits 0" "$install_rc" "0"
assert_contains "install --dry-run: enabled lane's label rendered" "$install_out" "com.spomni.sync.${install_enabled_lane}"
assert_contains "install --dry-run: enabled lane's interval rendered" "$install_out" "<integer>300</integer>"
assert_contains "install --dry-run: scheduler path rendered" "$install_out" "$CLI"
assert_contains "install --dry-run: data-dir rendered" "$install_out" "$cli_data_dir"
assert_not_contains "install --dry-run: disabled lane excluded" "$install_out" "com.spomni.sync.${install_disabled_lane}"

if [ -f "$HOME/Library/LaunchAgents/com.spomni.sync.${install_enabled_lane}.plist" ]; then
  fail "install --dry-run: must not write a real plist to ~/Library/LaunchAgents"
else
  pass "install --dry-run: no plist written to ~/Library/LaunchAgents"
fi

# =============================================================================
# 7. CLI uninstall --dry-run — prints actions, performs none
# =============================================================================

uninstall_out="$("$CLI" uninstall "$install_enabled_lane" --dry-run --data-dir "$cli_data_dir" 2>&1)"
uninstall_rc=$?
assert_eq "uninstall --dry-run: exits 0" "$uninstall_rc" "0"
assert_contains "uninstall --dry-run: prints bootout action" "$uninstall_out" "launchctl bootout"
assert_contains "uninstall --dry-run: prints remove action" "$uninstall_out" "Would remove"
assert_contains "uninstall --dry-run: names the target label" "$uninstall_out" "com.spomni.sync.${install_enabled_lane}"

# =============================================================================
# 8. CLI status — row per configured lane, malformed config -> exit 1
# =============================================================================

status_out="$("$CLI" status --data-dir "$cli_data_dir" 2>&1)"
status_rc=$?
assert_eq "status: exits 0 on valid config" "$status_rc" "0"
assert_contains "status: header row present" "$status_out" "LANE"

enabled_row="$(printf '%s\n' "$status_out" | grep "^${install_enabled_lane} " || true)"
if [ -n "$enabled_row" ]; then
  pass "status: enabled lane emits exactly one row"
else
  fail "status: expected a row for $install_enabled_lane, got: $status_out"
fi
assert_contains "status: enabled lane row shows ENABLED=true" "$enabled_row" "true"
assert_contains "status: enabled lane row shows never-run" "$enabled_row" "NEVER_RUN"
assert_contains "status: enabled lane row shows not-installed" "$enabled_row" "no"

disabled_row="$(printf '%s\n' "$status_out" | grep "^${install_disabled_lane} " || true)"
if [ -n "$disabled_row" ]; then
  pass "status: disabled lane still emits exactly one row"
else
  fail "status: expected a row for $install_disabled_lane, got: $status_out"
fi
assert_contains "status: disabled lane row shows ENABLED=false" "$disabled_row" "false"
assert_contains "status: disabled lane row shows not-installed" "$disabled_row" "no"

status_row_count="$(printf '%s\n' "$status_out" | grep -c "^${LANE_NS}-install-" || true)"
assert_eq "status: exactly one row per configured lane (2 configured)" "$status_row_count" "2"

# LEGACY-row coverage (the pre-rename label-prefix detection in `status`, see
# LEGACY_LABEL_PREFIX in sync-scheduler.sh) is intentionally NOT tested here:
# the CLI's plist paths are always
# $HOME/Library/LaunchAgents (no --home / HOME-override flag exists to
# sandbox them, unlike --data-dir), so planting a fake legacy plist would
# write into the real invoking user's LaunchAgents directory. Skipped rather
# than risk polluting the host running this suite.

status_bad_data_dir="$SANDBOX/cli-data-bad"
mkdir -p "$status_bad_data_dir"
status_bad_cfg="$(sync_config_path "$status_bad_data_dir")"
mkdir -p "$(dirname "$status_bad_cfg")"
printf '%s\t60\ttrue\n' "${LANE_NS}-status-bad" > "$status_bad_cfg"

"$CLI" status --data-dir "$status_bad_data_dir" >/dev/null 2>&1
status_bad_rc=$?
assert_eq "status: malformed config -> exit 1" "$status_bad_rc" "1"

# =============================================================================
# 9. mcp-lane-tick.sh — headless-session wrapper (plan 28 D2), driven by the
#    offline stub-claude.sh fixture. Covers tick's every exit path + flag
#    construction + watchdog, preflight's pass/fail paths, sync_run_lane
#    integration, and the updated core template parsing under sync_lanes_list.
# =============================================================================

MCP_TICK="$REPO_ROOT/packages/connectors/scripts/mcp-lane-tick.sh"
STUB_CLAUDE="$REPO_ROOT/packages/connectors/tests/fixtures/stub-claude.sh"

if [ ! -x "$MCP_TICK" ]; then
  fail "mcp-lane-tick.sh: expected executable at $MCP_TICK"
elif [ ! -x "$STUB_CLAUDE" ]; then
  fail "stub-claude.sh: expected executable at $STUB_CLAUDE"
else

  # NOTE on capture style below: the wrapper's watchdog runs in a backgrounded
  # subshell (`( sleep N; ... ) &`) that is not exec-optimized (it has code
  # after the sleep), so `kill "$WATCHDOG_PID"` only reaps the subshell's own
  # PID — the `sleep` it forked internally is orphaned (reparented to pid 1)
  # and keeps the wrapper's inherited stdout/stderr fd open for the rest of
  # its duration. `x="$(cmd)"` command substitution blocks until every holder
  # of that pipe's write end closes it, so capturing via `$(...)` here would
  # hang for up to --timeout-seconds (default 900s). Redirecting to a real
  # file instead (as sync_run_lane itself does in production) sidesteps this
  # — a file redirect doesn't wait on orphaned fd holders.
  tick_out_file="$SANDBOX/tick-out.txt"

  # --- (i) tick-ok ---
  STUB_CLAUDE_MODE=ok "$MCP_TICK" tick --claude-bin "$STUB_CLAUDE" --prompt "/gmail-sweep pages=4" --allowed-tools "mcp__claude_ai_Gmail__*,Bash,Read,Write" --timeout-seconds 5 > "$tick_out_file" 2>&1
  tick_ok_rc=$?
  tick_ok_out="$(cat "$tick_out_file" 2>/dev/null)"
  assert_eq "mcp-lane-tick tick: ok mode -> exit 0" "$tick_ok_rc" "0"
  assert_contains "mcp-lane-tick tick: ok mode -> tick-ok in output" "$tick_ok_out" "tick-ok"

  # --- (ii) argv construction ---
  argv_file="$SANDBOX/stub-argv.txt"
  rm -f "$argv_file"
  argv_prompt="/gmail-sweep pages=4"
  argv_tools="mcp__claude_ai_Gmail__*,Bash,Read,Write"
  STUB_CLAUDE_MODE=ok STUB_CLAUDE_ARGV_FILE="$argv_file" \
    "$MCP_TICK" tick --claude-bin "$STUB_CLAUDE" --prompt "$argv_prompt" \
    --allowed-tools "$argv_tools" --max-turns 7 --timeout-seconds 5 >/dev/null 2>&1
  argv_content="$(cat "$argv_file" 2>/dev/null)"
  assert_contains "mcp-lane-tick tick: argv carries --allowedTools <csv>" "$argv_content" "$(printf -- '--allowedTools\n%s' "$argv_tools")"
  assert_contains "mcp-lane-tick tick: argv carries --max-turns <n>" "$argv_content" "$(printf -- '--max-turns\n7')"
  assert_contains "mcp-lane-tick tick: argv carries --permission-mode acceptEdits" "$argv_content" "$(printf -- '--permission-mode\nacceptEdits')"
  assert_contains "mcp-lane-tick tick: argv carries -p <prompt>" "$argv_content" "$(printf -- '-p\n%s' "$argv_prompt")"

  # --- (iii) nosummary -> exit 4 ---
  STUB_CLAUDE_MODE=nosummary "$MCP_TICK" tick --claude-bin "$STUB_CLAUDE" --prompt "hi" --allowed-tools "Bash" --timeout-seconds 5 > "$tick_out_file" 2>&1
  tick_nosummary_rc=$?
  tick_nosummary_out="$(cat "$tick_out_file" 2>/dev/null)"
  assert_eq "mcp-lane-tick tick: nosummary mode -> exit 4" "$tick_nosummary_rc" "4"
  assert_contains "mcp-lane-tick tick: nosummary mode -> reason=no-summary" "$tick_nosummary_out" "reason=no-summary"

  # --- (iv) claude's own nonzero exit propagates ---
  STUB_CLAUDE_MODE=exit7 "$MCP_TICK" tick --claude-bin "$STUB_CLAUDE" --prompt "hi" --allowed-tools "Bash" --timeout-seconds 5 > "$tick_out_file" 2>&1
  tick_exit7_rc=$?
  tick_exit7_out="$(cat "$tick_out_file" 2>/dev/null)"
  assert_eq "mcp-lane-tick tick: exit7 mode -> exit 7 (propagated)" "$tick_exit7_rc" "7"
  assert_contains "mcp-lane-tick tick: exit7 mode -> reason=exit=7" "$tick_exit7_out" "reason=exit=7"

  # --- (v) watchdog timeout ---
  timeout_start="$(date +%s)"
  STUB_CLAUDE_MODE=sleep "$MCP_TICK" tick --claude-bin "$STUB_CLAUDE" --prompt "hi" --allowed-tools "Bash" --timeout-seconds 2 > "$tick_out_file" 2>&1
  tick_timeout_rc=$?
  tick_timeout_out="$(cat "$tick_out_file" 2>/dev/null)"
  timeout_end="$(date +%s)"
  timeout_elapsed=$((timeout_end - timeout_start))
  assert_eq "mcp-lane-tick tick: watchdog timeout -> exit 3" "$tick_timeout_rc" "3"
  assert_contains "mcp-lane-tick tick: watchdog timeout -> reason=timeout" "$tick_timeout_out" "reason=timeout"
  if [ "$timeout_elapsed" -lt 25 ]; then
    pass "mcp-lane-tick tick: watchdog timeout completes well under wall-clock budget (${timeout_elapsed}s)"
  else
    fail "mcp-lane-tick tick: watchdog timeout took too long (${timeout_elapsed}s, expected < 25s)"
  fi

  # --- (vi) preflight ---
  STUB_CLAUDE_MODE=tools-full "$MCP_TICK" preflight --claude-bin "$STUB_CLAUDE" --lane gmail > "$tick_out_file" 2>&1
  preflight_full_rc=$?
  preflight_full_out="$(cat "$tick_out_file" 2>/dev/null)"
  assert_eq "mcp-lane-tick preflight: gmail, all tools present -> exit 0" "$preflight_full_rc" "0"
  assert_contains "mcp-lane-tick preflight: gmail, all tools present -> preflight-ok" "$preflight_full_out" "preflight-ok"

  STUB_CLAUDE_MODE=tools-missing "$MCP_TICK" preflight --claude-bin "$STUB_CLAUDE" --lane calendar > "$tick_out_file" 2>&1
  preflight_missing_rc=$?
  preflight_missing_out="$(cat "$tick_out_file" 2>/dev/null)"
  assert_eq "mcp-lane-tick preflight: calendar, missing tool -> exit 2" "$preflight_missing_rc" "2"
  assert_contains "mcp-lane-tick preflight: calendar, missing tool -> preflight-fail" "$preflight_missing_out" "preflight-fail"
  assert_contains "mcp-lane-tick preflight: calendar, missing tool -> names list_events" "$preflight_missing_out" "list_events"

  # --- (vii) sync_run_lane integration ---
  mcp_run_data_dir="$SANDBOX/mcp-run-data"
  mkdir -p "$mcp_run_data_dir"
  mcp_run_cfg="$SANDBOX/mcp-run-config.tsv"

  mcp_fail_lane="${LANE_NS}-mcp-exit7"
  mcp_ok_lane="${LANE_NS}-mcp-ok"

  cat > "$mcp_run_cfg" <<EOF
${mcp_fail_lane}	60	true	STUB_CLAUDE_MODE=exit7 /bin/bash ${MCP_TICK} tick --claude-bin ${STUB_CLAUDE} --prompt "hi" --allowed-tools "Bash" --timeout-seconds 5
${mcp_ok_lane}	60	true	STUB_CLAUDE_MODE=ok /bin/bash ${MCP_TICK} tick --claude-bin ${STUB_CLAUDE} --prompt "hi" --allowed-tools "Bash" --timeout-seconds 5
EOF

  sync_run_lane "$mcp_run_cfg" "$mcp_run_data_dir" "$mcp_fail_lane"
  mcp_fail_run_rc=$?
  assert_eq "sync_run_lane + mcp-lane-tick: exit7 lane propagates exit 7" "$mcp_fail_run_rc" "7"
  mcp_fail_state="$(sync_state_read "$mcp_run_data_dir" "$mcp_fail_lane")"
  mcp_fail_state_exit="$(printf '%s' "$mcp_fail_state" | awk -F'\t' '{print $3}')"
  assert_eq "sync_run_lane + mcp-lane-tick: exit7 lane state last_exit=7" "$mcp_fail_state_exit" "7"
  mcp_fail_log="$(cat "$(sync_log_file "$mcp_run_data_dir" "$mcp_fail_lane")" 2>/dev/null)"
  assert_contains "sync_run_lane + mcp-lane-tick: exit7 lane log contains tick-fail" "$mcp_fail_log" "tick-fail"

  sync_run_lane "$mcp_run_cfg" "$mcp_run_data_dir" "$mcp_ok_lane"
  mcp_ok_run_rc=$?
  assert_eq "sync_run_lane + mcp-lane-tick: ok lane exits 0" "$mcp_ok_run_rc" "0"
  mcp_ok_state="$(sync_state_read "$mcp_run_data_dir" "$mcp_ok_lane")"
  mcp_ok_state_exit="$(printf '%s' "$mcp_ok_state" | awk -F'\t' '{print $3}')"
  assert_eq "sync_run_lane + mcp-lane-tick: ok lane state last_exit=0" "$mcp_ok_state_exit" "0"

  # --- (viii) core template parses under sync_lanes_list ---
  template_src="$REPO_ROOT/packages/core/templates/sync-lanes.tsv"
  template_copy_dir="$SANDBOX/template-check"
  mkdir -p "$template_copy_dir"
  template_copy="$template_copy_dir/lanes.tsv"
  sed -e "s#<ABS-REPO-ROOT>#$REPO_ROOT#g" -e "s#<ABS-CLAUDE-BIN>#$STUB_CLAUDE#g" "$template_src" > "$template_copy"

  template_rows="$(sync_lanes_list "$template_copy")"
  template_rc=$?
  assert_eq "core template sync-lanes.tsv: parses cleanly under sync_lanes_list" "$template_rc" "0"
  template_row_count="$(printf '%s\n' "$template_rows" | grep -c .)"
  assert_eq "core template sync-lanes.tsv: exactly 3 rows" "$template_row_count" "3"

  # --- (ix) tick/subcommand argument errors ---
  "$MCP_TICK" tick --claude-bin "$STUB_CLAUDE" --allowed-tools "Bash" >/dev/null 2>/dev/null
  tick_missing_flag_rc=$?
  tick_missing_flag_err="$("$MCP_TICK" tick --claude-bin "$STUB_CLAUDE" --allowed-tools "Bash" 2>&1 >/dev/null)"
  assert_eq "mcp-lane-tick tick: missing required --prompt -> exit 2" "$tick_missing_flag_rc" "2"
  assert_contains "mcp-lane-tick tick: missing required --prompt -> usage on stderr" "$tick_missing_flag_err" "Usage:"

  "$MCP_TICK" bogus-subcommand >/dev/null 2>/dev/null
  unknown_subcommand_rc=$?
  assert_eq "mcp-lane-tick: unknown subcommand -> exit 2" "$unknown_subcommand_rc" "2"

fi

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
