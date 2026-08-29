#!/bin/bash
# beeper-sweep.sh — sweep orchestrator for the Beeper capture lane.
#
# Usage:
#   beeper-sweep.sh [--data-dir <dir>]
#   beeper-sweep.sh [--data-dir <dir>] --list-accounts
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
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
NORMALIZE_SCRIPT="${REPO_ROOT}/packages/connectors/scripts/normalize-capture.sh"

DATA_DIR="${REPO_ROOT}/data/connectors/beeper-in"
LIST_ACCOUNTS=0

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
    *)
      echo "beeper-sweep.sh: unrecognized argument: $1" >&2
      exit 1
      ;;
  esac
done

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib.sh"

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
# ---------------------------------------------------------------------------
install_run_trap

case "$LOAD_RC" in
  2)
    run_log "skip-disabled" 0 0 0
    exit 0
    ;;
  3)
    run_log "skip-no-token" 0 0 0
    exit 0
    ;;
esac

RUN_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

case "$STORE_DIR" in
  /*) STORE_DIR_ABS="$STORE_DIR" ;;
  *) STORE_DIR_ABS="${REPO_ROOT}/${STORE_DIR}" ;;
esac

# Step 2: reachability probe.
info_resp="$(beeper_get "/v1/info")"
info_rc=$?
if [ "$info_rc" -ne 0 ] || [ -z "$info_resp" ]; then
  run_log "skip-unreachable" 0 0 0
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

# Step 4: list chats bounded by last-sweep (first page only on a first run).
LAST_SWEEP=""
if [ -f "$LAST_SWEEP_FILE" ]; then
  LAST_SWEEP="$(cat "$LAST_SWEEP_FILE" 2>/dev/null)"
fi

CHATS_TMP="$(mktemp)"
if ! list_new_chats "$LAST_SWEEP" > "$CHATS_TMP"; then
  rm -f "$CHATS_TMP"
  run_log "skip-unreachable" 0 0 0 "$WARN"
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

  existing_cursor="$(cursor_get "$chat_id")"
  cursor_rc=$?
  if [ "$cursor_rc" -eq 0 ]; then
    fetch_result="$(fetch_new_messages "$chat_id" "$existing_cursor")"
  else
    fetch_result="$(fetch_new_messages "$chat_id")"
  fi
  fetch_rc=$?
  if [ "$fetch_rc" -ne 0 ]; then
    WARN="${WARN}${WARN:+,}${chat_id}=fetch-failed"
    continue
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

  set -- "$STORE_DIR_ABS" --source beeper --type other --captured-at "$RUN_START"
  while IFS= read -r hint; do
    [ -z "$hint" ] && continue
    set -- "$@" --hint "$hint"
  done < "$HINTS_TMP"
  rm -f "$HINTS_TMP"

  normalize_out="$(printf '%s\n' "$event_body" | "$NORMALIZE_SCRIPT" "$@" 2>/dev/null)"
  normalize_rc=$?

  if [ "$normalize_rc" -eq 0 ]; then
    EVENTS_COUNT=$((EVENTS_COUNT + 1))
    [ -n "$final_cursor" ] && cursor_set "$chat_id" "$final_cursor"
  else
    QUARANTINED_COUNT=$((QUARANTINED_COUNT + 1))
  fi
done < "$CHATS_TMP"

rm -f "$CHATS_TMP"

# Step 8: last-sweep advances only because chat listing succeeded above.
printf '%s\n' "$RUN_START" > "$LAST_SWEEP_FILE"

if [ "$QUARANTINED_COUNT" -gt 0 ]; then
  OUTCOME="partial"
else
  OUTCOME="ok"
fi

run_log "$OUTCOME" "$CHATS_COUNT" "$EVENTS_COUNT" "$QUARANTINED_COUNT" "$WARN"
exit 0
