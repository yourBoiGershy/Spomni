#!/bin/bash
# beeper-sweep.sh — sweep orchestrator for the Beeper capture lane.
#
# Usage:
#   beeper-sweep.sh [--data-dir <dir>]
#   beeper-sweep.sh [--data-dir <dir>] --list-accounts
#   beeper-sweep.sh [--data-dir <dir>] --backfill
#
# Implements the plan's Sweep algorithm (steps 1-8), see
# docs/plans/2026-08-29-13-beeper-capture.md:
#   1. Load config + token. Missing/empty config -> skip-disabled. No token
#      -> skip-no-token. Both log + exit 0.
#   2. GET /v1/info as a reachability probe; any transport failure ->
#      skip-unreachable, exit 0 (no retries, cursors catch up next run).
#   3. GET /v1/accounts; enabled accountIDs absent or not
#      connected/backfilling are noted via warn=..., never fatal.
#   4. List chats bounded by last-sweep (or first-page-only on a first run)
#      via list_new_chats.
#   5. Per chat, fetch new messages via fetch_new_messages (cursor catch-up,
#      or newest page on a chat's first capture).
#   6. Non-empty chat -> one capture event per chat per run, piped through
#      the shared normalizer with hints for the title + unique non-self
#      senders.
#   7. Normalizer exit 0 -> advance the chat's cursor; exit 1 -> quarantined,
#      cursor left unadvanced, run becomes partial.
#   8. Update last-sweep (only if chat listing itself succeeded) and append
#      the run's status line.
#
# --list-accounts: read-only report mode. Prints "accountID network status"
# rows from GET /v1/accounts and exits. No store writes, no cursor writes,
# no run-log line.
#
# --backfill: onboarding one-shot deep-history mode (plan 24 U6, D6 fix).
# Resolves the onboarding-backfill window (packages/connectors/scripts/
# resolve-backfill-window.sh) and, per chat, paginates messages backward
# (direction=before) from the chat's coverage-floor.tsv cursor (D6: the
# oldest cursor of the incremental lane's first-ever fetched page — recorded
# once by this same script's incremental path) down to the window start, so
# it only ever fetches history the incremental lane's first newest-page
# fetch didn't already re-cover. A chat with no incremental capture at all
# yet has no floor: backfill starts from the newest page instead (unchanged
# pre-D6 behavior, still correct there). A chat whose first incremental
# capture predates this fix has no floor either: the legacy fallback derives
# an oldest-covered timestamp from that chat's existing inbox capture events
# and excludes messages at/after it. If bridge history is exhausted before
# reaching the window start, the run's WARN records
# `<chatID>=history-clamped@<oldest_ts>` — never silently implying full-
# window coverage. State is fully isolated (D5): backfill-cursors.tsv +
# backfill-last-sweep, siblings of the incremental cursors.tsv/last-sweep —
# this mode never reads chat listing from, or writes cursors/last-sweep/
# coverage-floor.tsv to, the incremental files (coverage-floor.tsv is
# incremental-owned, same as cursors.tsv). Logged to the same runs.log with
# a `backfill-` outcome marker. One-shot; not wired into the sync scheduler.
#
# Token file permissions: before reading the token, checks that the token
# file isn't group- or world-readable; if it is, warns to stderr (with a
# chmod 600 remedy) and continues — never fatal.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
NORMALIZE_SCRIPT="${REPO_ROOT}/packages/connectors/scripts/normalize-capture.sh"

RESOLVE_WINDOW_SCRIPT="${REPO_ROOT}/packages/connectors/scripts/resolve-backfill-window.sh"

DATA_DIR="${REPO_ROOT}/data/connectors/beeper-in"
LIST_ACCOUNTS=0
BACKFILL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --data-dir)
      DATA_DIR="${2:-}"
      shift 2
      ;;
    --list-accounts)
      LIST_ACCOUNTS=1
      shift
      ;;
    --backfill)
      BACKFILL=1
      shift
      ;;
    *)
      echo "beeper-sweep.sh: unrecognized argument: $1" >&2
      exit 1
      ;;
  esac
done

# Exported so lib.sh's exit trap (install_run_trap) can mark a synthesized
# `error` outcome as `backfill-error` when this mode is active.
BEEPER_BACKFILL="$BACKFILL"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

# warn_if_token_readable <path> — flags a token file that's readable by
# group/other (macOS stat, falling back to GNU stat). Never fatal; just a
# stderr nudge toward chmod 600.
warn_if_token_readable() {
  token_path="$1"
  [ -f "$token_path" ] || return 0
  perm="$(stat -f %Lp "$token_path" 2>/dev/null)"
  if [ -z "$perm" ]; then
    perm="$(stat -c %a "$token_path" 2>/dev/null)"
  fi
  [ -z "$perm" ] && return 0
  other_bits="${perm#"${perm%??}"}"
  case "$other_bits" in
    00) ;;
    *) echo "WARN: token file ${token_path} is readable by others — run: chmod 600 ${token_path}" >&2 ;;
  esac
}

mkdir -p "$DATA_DIR"

beeper_load_config "$DATA_DIR"
LOAD_RC=$?

# ---------------------------------------------------------------------------
# --list-accounts: independent of the enabled_account_ids gate (its whole
# point is helping the user populate that list) but still needs a base URL
# and token. No cursor/store writes, no run.log line.
# ---------------------------------------------------------------------------
if [ "$LIST_ACCOUNTS" -eq 1 ]; then
  [ -z "${BASE_URL:-}" ] && BASE_URL="http://127.0.0.1:23373"

  if [ -z "${TOKEN_FILE:-}" ] || [ ! -f "$TOKEN_FILE" ]; then
    echo "beeper-sweep.sh: no token at ${TOKEN_FILE:-${DATA_DIR}/token}" >&2
    exit 1
  fi

  warn_if_token_readable "$TOKEN_FILE"

  if [ -z "${BEEPER_TOKEN:-}" ]; then
    BEEPER_TOKEN="$(head -n 1 "$TOKEN_FILE" 2>/dev/null)"
  fi
  if [ -z "$BEEPER_TOKEN" ]; then
    echo "beeper-sweep.sh: token file is empty: ${TOKEN_FILE}" >&2
    exit 1
  fi

  accounts_resp="$(beeper_get "/v1/accounts")"
  accounts_rc=$?
  if [ "$accounts_rc" -ne 0 ] || [ -z "$accounts_resp" ]; then
    echo "beeper-sweep.sh: GET /v1/accounts failed" >&2
    exit 1
  fi

  printf '%s' "$accounts_resp" | jq -r \
    '.[] | [(.accountID // ""), (.network // "-"), (.status // "-")] | @tsv' | \
    awk -F'\t' '{printf "%-30s  %-16s  %s\n", $1, $2, $3}'
  exit 0
fi

# ---------------------------------------------------------------------------
# Normal sweep. RUNS_LOG is set by beeper_load_config on every code path
# (including the early skip-disabled/skip-no-token returns), so the trap is
# safe to arm right away.
#
# LOG_PREFIX carries the `backfill-` outcome marker (plan 24 U6) onto every
# run_log call below when --backfill is active; incremental invocation
# (LOG_PREFIX="") is byte-identical to before this flag existed.
# ---------------------------------------------------------------------------
install_run_trap

LOG_PREFIX=""
[ "$BACKFILL" -eq 1 ] && LOG_PREFIX="backfill-"

case "$LOAD_RC" in
  2)
    run_log "${LOG_PREFIX}skip-disabled" 0 0 0
    exit 0
    ;;
  3)
    run_log "${LOG_PREFIX}skip-no-token" 0 0 0
    exit 0
    ;;
esac

warn_if_token_readable "$TOKEN_FILE"

RUN_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

case "$STORE_DIR" in
  /*) STORE_DIR_ABS="$STORE_DIR" ;;
  *) STORE_DIR_ABS="${REPO_ROOT}/${STORE_DIR}" ;;
esac

# --backfill only: resolve the onboarding-backfill window and set up the
# isolated backfill-cursors.tsv/backfill-last-sweep state (D5) before any
# network call. <data-dir> for resolve-backfill-window.sh is the private
# data root (sibling of data/store, parent of data/connectors/*) — derived
# from DATA_DIR (data/connectors/beeper-in) by stripping two path segments,
# per docs/data-layout.md's `data/{store,connectors}` shape.
WINDOW_START_ISO=""
if [ "$BACKFILL" -eq 1 ]; then
  ROOT_DATA_DIR="$(cd "${DATA_DIR}/../.." 2>/dev/null && pwd)"
  if [ -z "$ROOT_DATA_DIR" ]; then
    run_log "backfill-error" 0 0 0 "could not resolve private data root from --data-dir ${DATA_DIR}"
    exit 1
  fi

  window_line="$("$RESOLVE_WINDOW_SCRIPT" "$ROOT_DATA_DIR")"
  window_rc=$?
  if [ "$window_rc" -ne 0 ] || [ -z "$window_line" ]; then
    run_log "backfill-error" 0 0 0 "resolve-backfill-window.sh failed (see stderr)"
    exit 1
  fi
  WINDOW_START_ISO="${window_line%%	*}"

  BACKFILL_CURSORS_FILE="${DATA_DIR}/backfill-cursors.tsv"
  BACKFILL_LAST_SWEEP_FILE="${DATA_DIR}/backfill-last-sweep"
fi

# Step 2: reachability probe.
info_resp="$(beeper_get "/v1/info")"
info_rc=$?
if [ "$info_rc" -ne 0 ] || [ -z "$info_resp" ]; then
  run_log "${LOG_PREFIX}skip-unreachable" 0 0 0
  exit 0
fi

# Step 3: account status check. Never fatal — noted via warn=.
WARN=""
accounts_resp="$(beeper_get "/v1/accounts")"
accounts_rc=$?
if [ "$accounts_rc" -eq 0 ] && [ -n "$accounts_resp" ]; then
  for account_id in $ENABLED_ACCOUNT_IDS; do
    acct_status="$(printf '%s' "$accounts_resp" | jq -r --arg id "$account_id" \
      '.[] | select(.accountID == $id) | .status // empty' 2>/dev/null)"
    if [ -z "$acct_status" ]; then
      WARN="${WARN}${WARN:+,}${account_id}=missing"
    elif [ "$acct_status" != "connected" ] && [ "$acct_status" != "backfilling" ]; then
      WARN="${WARN}${WARN:+,}${account_id}=${acct_status}"
    fi
  done
else
  WARN="${WARN}${WARN:+,}accounts-check-failed"
fi

# Step 4: list chats bounded by last-sweep (first page only on a first
# run); --backfill instead bounds by the resolved window start, deliberately
# reaching deep (list_new_chats already paginates multi-page whenever its
# `since` argument is non-empty).
LAST_SWEEP=""
if [ "$BACKFILL" -eq 1 ]; then
  LAST_SWEEP="$WINDOW_START_ISO"
elif [ -f "$LAST_SWEEP_FILE" ]; then
  LAST_SWEEP="$(cat "$LAST_SWEEP_FILE" 2>/dev/null)"
fi

CHATS_TMP="$(mktemp)"
if ! list_new_chats "$LAST_SWEEP" > "$CHATS_TMP"; then
  rm -f "$CHATS_TMP"
  run_log "${LOG_PREFIX}skip-unreachable" 0 0 0 "$WARN"
  exit 0
fi

CHATS_COUNT=0
EVENTS_COUNT=0
QUARANTINED_COUNT=0

# Steps 5-7: per collected chat, fetch new messages, batch into one capture
# event, normalize, advance the cursor only on normalizer success.
while IFS= read -r chat_json; do
  [ -z "$chat_json" ] && continue
  CHATS_COUNT=$((CHATS_COUNT + 1))

  chat_id="$(printf '%s' "$chat_json" | jq -r '.id // empty')"
  [ -z "$chat_id" ] && continue
  account_id="$(printf '%s' "$chat_json" | jq -r '.accountID // empty')"
  network="$(printf '%s' "$chat_json" | jq -r '.network // empty')"
  title="$(printf '%s' "$chat_json" | jq -r '.title // empty')"
  chat_type="$(printf '%s' "$chat_json" | jq -r '.type // empty')"

  # existing_cursor reads the *incremental* ledger (cursors.tsv) — used only
  # by the non-backfill (incremental) fetch below. --backfill (D6) starts
  # from this chat's coverage-floor.tsv cursor instead (see block below);
  # it never uses existing_cursor as its start bound (that was the D6 bug:
  # "before the incremental cursor" re-covers the incremental lane's own
  # newest page).
  existing_cursor="$(cursor_get "$chat_id")"
  cursor_rc=$?
  if [ "$BACKFILL" -eq 1 ]; then
    floor_cursor="$(coverage_floor_get "$chat_id")"
    floor_rc=$?
    if [ "$floor_rc" -eq 0 ]; then
      fetch_result="$(fetch_backfill_messages "$chat_id" "$floor_cursor" "$WINDOW_START_ISO")"
    else
      # No floor: either the chat has no incremental capture at all yet
      # (start from the newest page, pre-D6 behavior, correct here), or its
      # first incremental capture predates this fix (legacy fallback —
      # derive the oldest-covered timestamp from existing inbox events and
      # exclude anything at/after it).
      legacy_max_ts="$(beeper_legacy_oldest_covered_ts "$STORE_DIR_ABS" "$chat_id")"
      if [ -n "$legacy_max_ts" ]; then
        fetch_result="$(fetch_backfill_messages "$chat_id" "" "$WINDOW_START_ISO" "$legacy_max_ts")"
      else
        fetch_result="$(fetch_backfill_messages "$chat_id" "" "$WINDOW_START_ISO")"
      fi
    fi
  elif [ "$cursor_rc" -eq 0 ]; then
    fetch_result="$(fetch_new_messages "$chat_id" "$existing_cursor")"
  else
    fetch_result="$(fetch_new_messages "$chat_id")"
  fi
  fetch_rc=$?
  if [ "$fetch_rc" -ne 0 ]; then
    WARN="${WARN}${WARN:+,}${chat_id}=fetch-failed"
    continue
  fi

  # History clamp (D6): pagination exhausted bridge history before reaching
  # the resolved window start — say so, never imply full-window coverage.
  if [ "$BACKFILL" -eq 1 ]; then
    clamped="$(printf '%s' "$fetch_result" | jq -r '.clamped // false' 2>/dev/null)"
    if [ "$clamped" = "true" ]; then
      clamp_ts="$(printf '%s' "$fetch_result" | jq -r '.oldestTs // empty' 2>/dev/null)"
      WARN="${WARN}${WARN:+,}${chat_id}=history-clamped@${clamp_ts}"
    fi
  fi

  msg_count="$(printf '%s' "$fetch_result" | jq -r '.items | length' 2>/dev/null)"
  [ -z "$msg_count" ] && msg_count=0
  [ "$msg_count" -eq 0 ] && continue

  final_cursor="$(printf '%s' "$fetch_result" | jq -r '.finalCursor // empty')"

  # Step 6: hints = chat title + each unique non-self senderName/senderID.
  HINTS_TMP="$(mktemp)"
  [ -n "$title" ] && printf '%s\n' "$title" >> "$HINTS_TMP"
  printf '%s' "$fetch_result" | jq -r \
    '.items[] | select(.isSender != true) | (.senderName // .senderID // empty)' 2>/dev/null | \
    awk 'NF && !seen[$0]++' >> "$HINTS_TMP"

  event_body="$(printf '%s' "$fetch_result" | jq -c \
    --arg chatID "$chat_id" --arg accountID "$account_id" \
    --arg network "$network" --arg title "$title" --arg chatType "$chat_type" \
    '{chatID: $chatID, accountID: $accountID, network: $network, title: $title, chatType: $chatType, messages: .items}')"

  network_source="$network"
  [ -z "$network_source" ] && network_source="unknown"

  newest_ts="$(printf '%s' "$fetch_result" | jq -r '[.items[].timestamp] | max // empty' 2>/dev/null)"
  occurred_at=""
  if [ -n "$newest_ts" ]; then
    ts_no_z="${newest_ts%Z}"
    occurred_at="${ts_no_z%%.*}Z"
  fi

  set -- "$STORE_DIR_ABS" --source "beeper-in/${network_source}" --type chat-message --captured-at "$RUN_START"
  [ -n "$occurred_at" ] && set -- "$@" --occurred-at "$occurred_at"
  while IFS= read -r hint; do
    [ -z "$hint" ] && continue
    set -- "$@" --hint "$hint"
  done < "$HINTS_TMP"
  rm -f "$HINTS_TMP"

  normalize_out="$(printf '%s\n' "$event_body" | "$NORMALIZE_SCRIPT" "$@" 2>/dev/null)"
  normalize_rc=$?

  if [ "$normalize_rc" -eq 0 ]; then
    EVENTS_COUNT=$((EVENTS_COUNT + 1))
    if [ -n "$final_cursor" ]; then
      if [ "$BACKFILL" -eq 1 ]; then
        cursor_set "$chat_id" "$final_cursor" "$BACKFILL_CURSORS_FILE"
      else
        cursor_set "$chat_id" "$final_cursor"
        # Coverage floor (D6): only on this chat's first-ever incremental
        # capture (no prior cursor — cursor_rc from cursor_get above), record
        # the fetched page's oldest cursor once. Write-once: never advanced
        # again, never touched by --backfill except as its read-only start
        # bound.
        if [ "$cursor_rc" -ne 0 ]; then
          floor_cursor="$(printf '%s' "$fetch_result" | jq -r '.oldestCursor // empty' 2>/dev/null)"
          if [ -n "$floor_cursor" ] && ! coverage_floor_get "$chat_id" >/dev/null 2>&1; then
            coverage_floor_set "$chat_id" "$floor_cursor"
          fi
        fi
      fi
    fi
  else
    QUARANTINED_COUNT=$((QUARANTINED_COUNT + 1))
  fi
done < "$CHATS_TMP"

rm -f "$CHATS_TMP"

# Step 8: last-sweep advances only because chat listing succeeded above.
# --backfill writes only its own isolated backfill-last-sweep — cursors.tsv
# and last-sweep (the incremental files) are never touched by this mode.
if [ "$BACKFILL" -eq 1 ]; then
  printf '%s\n' "$RUN_START" > "$BACKFILL_LAST_SWEEP_FILE"
else
  printf '%s\n' "$RUN_START" > "$LAST_SWEEP_FILE"
fi

if [ "$QUARANTINED_COUNT" -gt 0 ]; then
  OUTCOME="${LOG_PREFIX}partial"
else
  OUTCOME="${LOG_PREFIX}ok"
fi

run_log "$OUTCOME" "$CHATS_COUNT" "$EVENTS_COUNT" "$QUARANTINED_COUNT" "$WARN"
exit 0
