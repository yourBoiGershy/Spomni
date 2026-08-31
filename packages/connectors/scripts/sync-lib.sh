#!/bin/bash
# sync-lib.sh — shared primitives for the plan-19 sync scheduler.
#
# Sourced by sync-scheduler.sh (and tests). Provides:
#   sync_config_path  — path to lanes.tsv under a data dir
#   sync_lanes_list / sync_lane_get — parse + validate lanes.tsv (contract
#     sync-lanes 1.0.0, see packages/core/contracts/sync-lanes.md)
#   sync_state_read / sync_state_write — per-lane last-run state (atomic)
#   sync_log_file / sync_log_append — per-lane log with rotation at 512000B
#   sync_export_env / sync_resolve_command — sync-lanes 1.1.0 {{...}}
#     placeholder expansion (REPO_ROOT/DATA_DIR/PRIVATE_DATA_ROOT/STORE_DIR/
#     CLAUDE_BIN) so a lane's command routes to the current checkout/store
#   sync_pre_pull — best-effort store refresh from origin before a lane runs
#     (skip with SPOMNI_NO_PREPULL=1)
#   sync_run_lane — run one lane's command (after placeholder expansion),
#     recording state + log; pre-pulls the store from origin first
#
# Side-effect-free on source: no `set -e`, no top-level work beyond function
# definitions and readonly constants. `set -u`-safe — callers may run under
# `set -u`; this file itself does not set it (sourced into caller's shell).
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile,
# no ${var,,}. All timestamps ISO-8601 UTC via `date -u +%Y-%m-%dT%H:%M:%SZ`.
#
# Not meant to be executed directly — `source` this file.

SYNC_LOG_ROTATE_BYTES=512000

# ---------------------------------------------------------------------------
# sync_config_path <data_dir> — echo the lanes.tsv path for a data dir.
# ---------------------------------------------------------------------------
sync_config_path() {
  data_dir="$1"
  printf '%s\n' "${data_dir}/connectors/sync-scheduler/lanes.tsv"
}

# ---------------------------------------------------------------------------
# _sync_validate_lane_row <file> <lineno> <line> — internal. Parses one
# non-blank, non-comment line as lane<TAB>interval_seconds<TAB>enabled<TAB>
# command. On success, sets _SYNC_LANE / _SYNC_INTERVAL / _SYNC_ENABLED /
# _SYNC_COMMAND and returns 0. On failure, prints
# "sync-lib: <file>:<lineno>: <reason>" to stderr and returns 1.
# ---------------------------------------------------------------------------
_sync_validate_lane_row() {
  file="$1"
  lineno="$2"
  line="$3"

  lane="$(printf '%s' "$line" | awk -F'\t' '{print $1}')"
  interval="$(printf '%s' "$line" | awk -F'\t' '{print $2}')"
  enabled="$(printf '%s' "$line" | awk -F'\t' '{print $3}')"
  command="$(printf '%s' "$line" | awk -F'\t' '{
    out = $4
    for (i = 5; i <= NF; i++) out = out "\t" $i
    print out
  }')"

  field_count="$(printf '%s' "$line" | awk -F'\t' '{print NF}')"
  if [ "$field_count" -lt 4 ]; then
    echo "sync-lib: ${file}:${lineno}: expected 4 tab-separated fields" >&2
    return 1
  fi

  case "$lane" in
    '')
      echo "sync-lib: ${file}:${lineno}: lane must match [a-z0-9-]+" >&2
      return 1
      ;;
  esac
  case "$lane" in
    *[!a-z0-9-]*)
      echo "sync-lib: ${file}:${lineno}: lane must match [a-z0-9-]+" >&2
      return 1
      ;;
  esac

  case "$interval" in
    ''|*[!0-9]*)
      echo "sync-lib: ${file}:${lineno}: interval_seconds must be an integer >= 60" >&2
      return 1
      ;;
  esac
  if [ "$interval" -lt 60 ]; then
    echo "sync-lib: ${file}:${lineno}: interval_seconds must be an integer >= 60" >&2
    return 1
  fi

  if [ "$enabled" != "true" ] && [ "$enabled" != "false" ]; then
    echo "sync-lib: ${file}:${lineno}: enabled must be true|false" >&2
    return 1
  fi

  if [ -z "$command" ]; then
    echo "sync-lib: ${file}:${lineno}: expected 4 tab-separated fields" >&2
    return 1
  fi

  _SYNC_LANE="$lane"
  _SYNC_INTERVAL="$interval"
  _SYNC_ENABLED="$enabled"
  _SYNC_COMMAND="$command"
  return 0
}

# ---------------------------------------------------------------------------
# sync_lanes_list <config_file> — validate the whole file; print one
# name<TAB>interval<TAB>enabled<TAB>command row per lane to stdout. Any
# malformed row (including duplicate lane names): message on stderr, exit 1,
# no stdout. Missing file: stderr note, exit 1.
# ---------------------------------------------------------------------------
sync_lanes_list() {
  config_file="$1"

  if [ ! -f "$config_file" ]; then
    echo "sync-lib: ${config_file}: no such config file" >&2
    return 1
  fi

  rows_tmp="$(mktemp)"
  seen_tmp="$(mktemp)"
  lineno=0
  status=0

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))

    case "$line" in
      ''|'#'*)
        continue
        ;;
    esac

    if ! _sync_validate_lane_row "$config_file" "$lineno" "$line"; then
      status=1
      break
    fi

    if grep -Fxq "$_SYNC_LANE" "$seen_tmp" 2>/dev/null; then
      echo "sync-lib: ${config_file}:${lineno}: duplicate lane '${_SYNC_LANE}'" >&2
      status=1
      break
    fi
    printf '%s\n' "$_SYNC_LANE" >> "$seen_tmp"

    printf '%s\t%s\t%s\t%s\n' "$_SYNC_LANE" "$_SYNC_INTERVAL" "$_SYNC_ENABLED" "$_SYNC_COMMAND" >> "$rows_tmp"
  done < "$config_file"

  if [ "$status" -eq 0 ]; then
    cat "$rows_tmp"
  fi

  rm -f "$rows_tmp" "$seen_tmp"
  return "$status"
}

# ---------------------------------------------------------------------------
# sync_lane_get <config_file> <lane> — print that lane's row
# (name<TAB>interval<TAB>enabled<TAB>command), exit 0; unknown lane -> exit 2
# (no output); invalid config -> exit 1 (propagates sync_lanes_list's stderr).
# ---------------------------------------------------------------------------
sync_lane_get() {
  config_file="$1"
  lane="$2"

  rows="$(sync_lanes_list "$config_file")"
  status=$?
  if [ "$status" -ne 0 ]; then
    return 1
  fi

  match="$(printf '%s\n' "$rows" | awk -F'\t' -v l="$lane" '$1 == l')"
  if [ -z "$match" ]; then
    return 2
  fi

  printf '%s\n' "$match"
  return 0
}

# ---------------------------------------------------------------------------
# sync_state_read <data_dir> <lane> — print "start<TAB>end<TAB>exit" or the
# literal NEVER_RUN if no state has been recorded yet. Always exit 0.
# ---------------------------------------------------------------------------
sync_state_read() {
  data_dir="$1"
  lane="$2"

  state_file="${data_dir}/connectors/sync-scheduler/state/${lane}.tsv"
  if [ ! -f "$state_file" ]; then
    echo "NEVER_RUN"
    return 0
  fi

  content="$(head -n 1 "$state_file" 2>/dev/null)"
  if [ -z "$content" ]; then
    echo "NEVER_RUN"
    return 0
  fi

  printf '%s\n' "$content"
  return 0
}

# ---------------------------------------------------------------------------
# sync_state_write <data_dir> <lane> <start_iso> <end_iso> <exit_code> —
# atomically (tmp+mv) write the lane's state file; creates dirs as needed.
# ---------------------------------------------------------------------------
sync_state_write() {
  data_dir="$1"
  lane="$2"
  start_iso="$3"
  end_iso="$4"
  exit_code="$5"

  state_dir="${data_dir}/connectors/sync-scheduler/state"
  mkdir -p "$state_dir"

  state_file="${state_dir}/${lane}.tsv"
  tmp_file="${state_file}.tmp.$$"

  printf '%s\t%s\t%s\n' "$start_iso" "$end_iso" "$exit_code" > "$tmp_file"
  mv -f "$tmp_file" "$state_file"
}

# ---------------------------------------------------------------------------
# sync_log_file <data_dir> <lane> — echo the lane's log path.
# ---------------------------------------------------------------------------
sync_log_file() {
  data_dir="$1"
  lane="$2"
  printf '%s\n' "${data_dir}/connectors/sync-scheduler/logs/${lane}.log"
}

# ---------------------------------------------------------------------------
# _sync_rotate_log <log_file> — internal. If log_file exists and is over
# SYNC_LOG_ROTATE_BYTES, move it to <log_file>.1 (mv -f, overwriting any
# prior rollover).
# ---------------------------------------------------------------------------
_sync_rotate_log() {
  log_file="$1"

  [ -f "$log_file" ] || return 0

  size="$(wc -c < "$log_file" 2>/dev/null | tr -d '[:space:]')"
  [ -z "$size" ] && size=0

  if [ "$size" -gt "$SYNC_LOG_ROTATE_BYTES" ]; then
    mv -f "$log_file" "${log_file}.1"
  fi
}

# ---------------------------------------------------------------------------
# sync_log_append <data_dir> <lane> <message> — append
# "<ISO-UTC> <message>" to the lane's log, rotating first if over the cap.
# Creates the logs dir as needed.
# ---------------------------------------------------------------------------
sync_log_append() {
  data_dir="$1"
  lane="$2"
  message="$3"

  logs_dir="${data_dir}/connectors/sync-scheduler/logs"
  mkdir -p "$logs_dir"

  log_file="${logs_dir}/${lane}.log"
  _sync_rotate_log "$log_file"

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s %s\n' "$ts" "$message" >> "$log_file"
}

# ---------------------------------------------------------------------------
# sync_export_env <data_dir> — export SPOMNI_REPO_ROOT, SPOMNI_DATA_DIR,
# SPOMNI_PRIVATE_DATA_ROOT, SPOMNI_STORE_DIR, SPOMNI_CLAUDE_BIN so a lane
# command can reference the current checkout/store without hardcoding paths.
# Honors SYNC_REPO_ROOT / SPOMNI_CLAUDE_BIN overrides from the caller's env.
# ---------------------------------------------------------------------------
sync_export_env() {
  data_dir="$1"

  if [ -n "${SYNC_REPO_ROOT:-}" ]; then
    SPOMNI_REPO_ROOT="$SYNC_REPO_ROOT"
  else
    SPOMNI_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  fi

  SPOMNI_DATA_DIR="$(cd "$data_dir" 2>/dev/null && pwd)"
  [ -n "$SPOMNI_DATA_DIR" ] || SPOMNI_DATA_DIR="$data_dir"

  SPOMNI_PRIVATE_DATA_ROOT="$(dirname "$SPOMNI_DATA_DIR")"

  SPOMNI_STORE_DIR="$(cd "$SPOMNI_DATA_DIR/store" 2>/dev/null && pwd -P)"
  [ -n "$SPOMNI_STORE_DIR" ] || SPOMNI_STORE_DIR="$SPOMNI_DATA_DIR/store"

  if [ -n "${SPOMNI_CLAUDE_BIN:-}" ]; then
    :
  elif command -v claude >/dev/null 2>&1; then
    SPOMNI_CLAUDE_BIN="$(command -v claude)"
  elif [ -x "$HOME/.claude/local/claude" ]; then
    SPOMNI_CLAUDE_BIN="$HOME/.claude/local/claude"
  else
    SPOMNI_CLAUDE_BIN="claude"
  fi

  export SPOMNI_REPO_ROOT SPOMNI_DATA_DIR SPOMNI_PRIVATE_DATA_ROOT SPOMNI_STORE_DIR SPOMNI_CLAUDE_BIN
}

# ---------------------------------------------------------------------------
# sync_resolve_command <data_dir> <command> — echo <command> with {{...}}
# placeholders expanded against <data_dir> (see sync_export_env). Unknown
# {{X}} tokens are left untouched. Calls sync_export_env as a side effect.
# ---------------------------------------------------------------------------
sync_resolve_command() {
  data_dir="$1"
  command="$2"

  sync_export_env "$data_dir"

  resolved="$command"
  resolved="${resolved//\{\{REPO_ROOT\}\}/$SPOMNI_REPO_ROOT}"
  resolved="${resolved//\{\{DATA_DIR\}\}/$SPOMNI_DATA_DIR}"
  resolved="${resolved//\{\{PRIVATE_DATA_ROOT\}\}/$SPOMNI_PRIVATE_DATA_ROOT}"
  resolved="${resolved//\{\{STORE_DIR\}\}/$SPOMNI_STORE_DIR}"
  resolved="${resolved//\{\{CLAUDE_BIN\}\}/$SPOMNI_CLAUDE_BIN}"

  printf '%s\n' "$resolved"
}

# ---------------------------------------------------------------------------
# sync_pre_pull <data_dir> <log_file> — refresh the store from origin/main
# before a lane's command runs, so an always-on base machine picks up pushes
# from cloud/phone sessions before it syncs or writes anything. Resolves the
# store dir exactly as {{STORE_DIR}} does (via sync_export_env). Skips
# silently when SPOMNI_NO_PREPULL=1, when the store dir is not itself a git
# repo (no .git entry), or when it has no origin remote. Otherwise runs
# store-sync.sh <store> pull, capturing output:
#   success — appends exactly one line "pre-pull: <ff|merge|none>" to
#             <log_file> (same classification store-sync's tick prints)
#   failure — appends the captured pull output plus one line
#             "pre-pull: failed (continuing)"; the lane still runs — capture
#             must never be lost to a network blip
# ALWAYS returns 0 (`set -e`-safe): a failed pre-pull never kills the lane.
# ---------------------------------------------------------------------------
sync_pre_pull() {
  prepull_data_dir="$1"
  prepull_log_file="$2"

  if [ "${SPOMNI_NO_PREPULL:-0}" = "1" ]; then
    return 0
  fi

  sync_export_env "$prepull_data_dir"
  prepull_store="$SPOMNI_STORE_DIR"

  # The store dir itself must be a repo toplevel (.git dir, or file for a
  # worktree) with an origin remote — anything else skips silently.
  [ -e "${prepull_store}/.git" ] || return 0
  git -C "$prepull_store" remote get-url origin >/dev/null 2>&1 || return 0

  prepull_head_before="$(git -C "$prepull_store" rev-parse HEAD 2>/dev/null || echo "")"

  prepull_rc=0
  prepull_out="$(bash "${SPOMNI_REPO_ROOT}/packages/core/scripts/store-sync.sh" "$prepull_store" pull 2>&1)" \
    || prepull_rc=$?

  if [ "$prepull_rc" -ne 0 ]; then
    {
      printf '%s\n' "$prepull_out"
      printf 'pre-pull: failed (continuing)\n'
    } >> "$prepull_log_file"
    return 0
  fi

  prepull_head_after="$(git -C "$prepull_store" rev-parse HEAD 2>/dev/null || echo "")"
  if [ "$prepull_head_before" = "$prepull_head_after" ]; then
    prepull_kind="none"
  elif git -C "$prepull_store" rev-parse -q --verify HEAD^2 >/dev/null 2>&1; then
    prepull_kind="merge"
  else
    prepull_kind="ff"
  fi
  printf 'pre-pull: %s\n' "$prepull_kind" >> "$prepull_log_file"
  return 0
}

# ---------------------------------------------------------------------------
# sync_run_lane <config_file> <data_dir> <lane> — unknown lane: stderr +
# exit 2. Disabled: sync_log_append "skip-disabled", exit 0. Enabled: log
# "run-start", record start, pre-pull the store (sync_pre_pull, best-effort,
# never fatal), run the lane's command via /bin/bash -c
# (caller's cwd unchanged) with combined stdout+stderr appended to the lane
# log, record end state, log "run-end exit=<code> duration=<s>s", exit with
# the command's exit code.
# ---------------------------------------------------------------------------
sync_run_lane() {
  config_file="$1"
  data_dir="$2"
  lane="$3"

  row="$(sync_lane_get "$config_file" "$lane")"
  status=$?
  if [ "$status" -eq 2 ]; then
    echo "sync-lib: unknown lane '${lane}'" >&2
    return 2
  elif [ "$status" -ne 0 ]; then
    return 1
  fi

  enabled="$(printf '%s' "$row" | awk -F'\t' '{print $3}')"
  command="$(printf '%s' "$row" | awk -F'\t' '{
    out = $4
    for (i = 5; i <= NF; i++) out = out "\t" $i
    print out
  }')"

  if [ "$enabled" != "true" ]; then
    sync_log_append "$data_dir" "$lane" "skip-disabled"
    return 0
  fi

  logs_dir="${data_dir}/connectors/sync-scheduler/logs"
  mkdir -p "$logs_dir"
  log_file="${logs_dir}/${lane}.log"

  sync_log_append "$data_dir" "$lane" "run-start"

  start_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  start_epoch="$(date -u +%s)"

  sync_export_env "$data_dir"
  resolved_command="$(sync_resolve_command "$data_dir" "$command")"

  sync_pre_pull "$data_dir" "$log_file"

  /bin/bash -c "$resolved_command" >> "$log_file" 2>&1
  cmd_exit=$?

  end_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  end_epoch="$(date -u +%s)"
  duration=$((end_epoch - start_epoch))

  sync_state_write "$data_dir" "$lane" "$start_iso" "$end_iso" "$cmd_exit"
  sync_log_append "$data_dir" "$lane" "run-end exit=${cmd_exit} duration=${duration}s"

  return "$cmd_exit"
}
