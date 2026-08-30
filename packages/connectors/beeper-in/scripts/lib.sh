# lib.sh — shared library for the beeper-in capture lane.
#
# Sourced by beeper-sweep.sh (and tests). Provides:
#   beeper_load_config <data_dir>  — load config.json + token, set globals
#   beeper_get <path-with-query>   — the ONLY HTTP call site in this sub-package
#   cursor_get / cursor_set        — cursors.tsv read/advance
#   run_log / install_run_trap     — runs.log writer + EXIT-trap safety net
#   list_new_chats / fetch_new_messages — pagination helpers over /v1/chats(/*/messages)
#   fetch_backfill_messages        — --backfill mode's direction=before pagination
#                                     helper (plan 24 U6); reads/writes no state of
#                                     its own — cursor isolation lives in the sweep
#
# Read-only forever: beeper_get is GET-only (no -X, no --data). Allowed paths:
# /v1/info, /v1/accounts, /v1/chats, /v1/chats/*/messages.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile,
# no ${var,,}. Requires jq (existing-lane precedent); falls back to python3
# for URL-encoding if jq is unavailable.
#
# Not meant to be executed directly — `source` this file.

# ---------------------------------------------------------------------------
# beeper_load_config <data_dir> — read config.json + token from the data dir;
# sets BASE_URL, STORE_DIR, ENABLED_ACCOUNT_IDS (newline-separated),
# MAX_CHATS_PER_RUN, MAX_PAGES_PER_CHAT, BEEPER_TOKEN, and path globals
# (CONFIG_FILE, TOKEN_FILE, CURSORS_FILE, RUNS_LOG, LAST_SWEEP_FILE).
# Return codes: 0 = loaded (config present, enabled_account_ids non-empty,
# token present); 2 = skip-disabled (missing/empty config or no enabled
# accounts); 3 = skip-no-token (config fine, token missing/empty).
# ---------------------------------------------------------------------------
beeper_load_config() {
  data_dir="$1"

  BEEPER_DATA_DIR="$data_dir"
  CONFIG_FILE="${data_dir}/config.json"
  TOKEN_FILE="${data_dir}/token"
  CURSORS_FILE="${data_dir}/cursors.tsv"
  RUNS_LOG="${data_dir}/runs.log"
  LAST_SWEEP_FILE="${data_dir}/last-sweep"

  if [ ! -f "$CONFIG_FILE" ]; then
    return 2
  fi

  BASE_URL="$(jq -r '.base_url // empty' "$CONFIG_FILE" 2>/dev/null)"
  [ -z "$BASE_URL" ] && BASE_URL="http://127.0.0.1:23373"

  STORE_DIR="$(jq -r '.store_dir // empty' "$CONFIG_FILE" 2>/dev/null)"

  MAX_CHATS_PER_RUN="$(jq -r '.max_chats_per_run // 50' "$CONFIG_FILE" 2>/dev/null)"
  [ -z "$MAX_CHATS_PER_RUN" ] && MAX_CHATS_PER_RUN=50

  MAX_PAGES_PER_CHAT="$(jq -r '.max_pages_per_chat // 20' "$CONFIG_FILE" 2>/dev/null)"
  [ -z "$MAX_PAGES_PER_CHAT" ] && MAX_PAGES_PER_CHAT=20

  ENABLED_ACCOUNT_IDS="$(jq -r '.enabled_account_ids[]? // empty' "$CONFIG_FILE" 2>/dev/null)"

  if [ -z "$ENABLED_ACCOUNT_IDS" ]; then
    return 2
  fi

  if [ ! -f "$TOKEN_FILE" ]; then
    return 3
  fi

  BEEPER_TOKEN="$(head -n 1 "$TOKEN_FILE" 2>/dev/null)"
  if [ -z "$BEEPER_TOKEN" ]; then
    return 3
  fi

  return 0
}

# ---------------------------------------------------------------------------
# beeper_urlencode <string> — RFC 3986 percent-encode; used for chat IDs and
# cursors (which may contain "!"/":"/other reserved chars) in path segments
# and query values. jq's @uri primary, python3 fallback (bash 3.2 safe).
# ---------------------------------------------------------------------------
beeper_urlencode() {
  if command -v jq >/dev/null 2>&1; then
    jq -rn --arg s "$1" '$s | @uri'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
  else
    printf '%s' "$1"
  fi
}

# ---------------------------------------------------------------------------
# beeper_get <path-with-query> — the ONLY HTTP call site in this sub-package.
# GET only, curl -sS --max-time 15, Bearer auth from $BEEPER_TOKEN. When
# $BEEPER_HTTP_STUB is set, execs that stub with the path instead of curl
# (stub prints a body to stdout, exits curl-style) so tests run fully
# offline against fixtures. No -X, no --data/-d — read-only forever.
# ---------------------------------------------------------------------------
beeper_get() {
  path="$1"

  if [ -n "${BEEPER_HTTP_STUB:-}" ]; then
    "$BEEPER_HTTP_STUB" "$path"
    return $?
  fi

  curl -sS --max-time 15 -H "Authorization: Bearer ${BEEPER_TOKEN}" "${BASE_URL}${path}"
}

# ---------------------------------------------------------------------------
# cursor_get <chatID> [file] — print the chat's newestCursor from the given
# cursors file on stdout and return 0 if found; return 1 (no output) if the
# chat has no saved cursor yet (its first capture is a newest-page fetch, no
# cursor). [file] defaults to $CURSORS_FILE (the incremental ledger); pass
# $BACKFILL_CURSORS_FILE explicitly to read the isolated backfill ledger
# instead — the two are never conflated (D5).
# ---------------------------------------------------------------------------
cursor_get() {
  chat_id="$1"
  file="${2:-$CURSORS_FILE}"

  [ -f "$file" ] || return 1

  awk -F'\t' -v id="$chat_id" '
    $1 == id { c = $2; found = 1 }
    END { if (found) { print c; exit 0 } else { exit 1 } }
  ' "$file"
}

# ---------------------------------------------------------------------------
# cursor_set <chatID> <cursor> [file] — rewrite the given cursors file via
# temp file + mv, replacing any existing line for chatID with the new
# cursor. [file] defaults to $CURSORS_FILE; pass $BACKFILL_CURSORS_FILE
# explicitly for backfill writes so the incremental ledger is never touched
# (D5). Callers must only advance a chat's cursor after its capture event
# normalized successfully (contract lives in the sweep, not here).
# ---------------------------------------------------------------------------
cursor_set() {
  chat_id="$1"
  cursor="$2"
  file="${3:-$CURSORS_FILE}"

  tmp="$(mktemp)"
  if [ -f "$file" ]; then
    awk -F'\t' -v id="$chat_id" '$1 != id' "$file" > "$tmp"
  fi
  printf '%s\t%s\n' "$chat_id" "$cursor" >> "$tmp"
  mv "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# run_log <outcome> <chats> <events> <quarantined> [warn] — append one
# greppable status line to runs.log per the plan's failure-posture format:
#   <ISO8601Z> <outcome> chats=<n> events=<n> quarantined=<n> [warn=…]
# Sets RUN_LOGGED=1 so install_run_trap's EXIT trap knows a line was written.
# ---------------------------------------------------------------------------
RUN_LOGGED=0

run_log() {
  outcome="$1"
  chats="$2"
  events="$3"
  quarantined="$4"
  warn="${5:-}"

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  line="${ts} ${outcome} chats=${chats} events=${events} quarantined=${quarantined}"
  if [ -n "$warn" ]; then
    line="${line} warn=${warn}"
  fi

  printf '%s\n' "$line" >> "$RUNS_LOG"
  RUN_LOGGED=1
}

# ---------------------------------------------------------------------------
# install_run_trap — arm an EXIT trap that writes an `error` status line if
# the script exits without run_log having been called (silence impossible).
# Call once, after beeper_load_config has set RUNS_LOG. If $BEEPER_BACKFILL
# is "1" the synthesized outcome carries the same `backfill-` marker used by
# the sweep's own explicit run_log calls in that mode.
# ---------------------------------------------------------------------------
install_run_trap() {
  trap '_beeper_run_exit_trap' EXIT
}

_beeper_run_exit_trap() {
  if [ "${RUN_LOGGED:-0}" -ne 1 ]; then
    outcome="error"
    [ "${BEEPER_BACKFILL:-0}" -eq 1 ] && outcome="backfill-error"
    run_log "$outcome" 0 0 0 "exited without logging a run status"
  fi
}

# ---------------------------------------------------------------------------
# list_new_chats [since-ISO8601Z] — GET /v1/chats with accountIDs repeated
# per $ENABLED_ACCOUNT_IDS, direction=before pagination. Emits each chat as
# one jq -c JSON object per line on stdout. Stops when a page's oldest
# lastActivity predates `since`, or $MAX_CHATS_PER_RUN chats have been
# collected, or the API reports no more pages. If `since` is empty (first
# run, no last-sweep yet), only the first page is fetched — capture-from-now-
# on, no deep backfill, per the plan's step 4. Returns 1 on a beeper_get
# failure (transport error); caller treats that as skip-unreachable.
# ---------------------------------------------------------------------------
list_new_chats() {
  since="${1:-}"

  ids_query=""
  for account_id in $ENABLED_ACCOUNT_IDS; do
    encoded_id="$(beeper_urlencode "$account_id")"
    ids_query="${ids_query}&accountIDs=${encoded_id}"
  done

  cursor=""
  count=0

  while :; do
    path="/v1/chats?direction=before${ids_query}"
    if [ -n "$cursor" ]; then
      encoded_cursor="$(beeper_urlencode "$cursor")"
      path="${path}&cursor=${encoded_cursor}"
    fi

    resp="$(beeper_get "$path")" || return 1
    [ -z "$resp" ] && return 1

    page_count="$(printf '%s' "$resp" | jq -r '.items | length' 2>/dev/null)"
    [ -z "$page_count" ] && page_count=0

    if [ "$page_count" -eq 0 ]; then
      break
    fi

    printf '%s' "$resp" | jq -c '.items[]'
    count=$((count + page_count))

    # First run (no since bound): first page only.
    if [ -z "$since" ]; then
      break
    fi

    oldest_activity="$(printf '%s' "$resp" | jq -r '.items[-1].lastActivity // empty')"
    if [ -n "$oldest_activity" ] && [ "$oldest_activity" \< "$since" ]; then
      break
    fi

    if [ "$MAX_CHATS_PER_RUN" -gt 0 ] && [ "$count" -ge "$MAX_CHATS_PER_RUN" ]; then
      break
    fi

    has_more="$(printf '%s' "$resp" | jq -r '.hasMore // false')"
    next_cursor="$(printf '%s' "$resp" | jq -r '.cursors.oldest // .oldestCursor // empty')"

    if [ "$has_more" != "true" ] || [ -z "$next_cursor" ]; then
      break
    fi
    cursor="$next_cursor"
  done
}

# ---------------------------------------------------------------------------
# fetch_new_messages <chatID> [cursor] — no cursor: single newest-page GET
# (the chat's first capture). With a cursor: loop direction=after while
# hasMore, up to $MAX_PAGES_PER_CHAT pages (remainder caught next run via
# the unadvanced cursor — nothing lost). Emits one JSON object on stdout:
#   {items: [Message, …], finalCursor: "<newestCursor or input cursor>"}
# Returns 1 on a beeper_get failure.
# ---------------------------------------------------------------------------
fetch_new_messages() {
  chat_id="$1"
  cursor="${2:-}"

  encoded_chat_id="$(beeper_urlencode "$chat_id")"
  items_tmp="$(mktemp)"
  final_cursor="$cursor"

  if [ -z "$cursor" ]; then
    path="/v1/chats/${encoded_chat_id}/messages"
    resp="$(beeper_get "$path")" || { rm -f "$items_tmp"; return 1; }
    if [ -z "$resp" ]; then
      rm -f "$items_tmp"
      return 1
    fi
    printf '%s' "$resp" | jq -c '.items[]?' >> "$items_tmp"
    fc="$(printf '%s' "$resp" | jq -r '.newestCursor // empty')"
    [ -n "$fc" ] && final_cursor="$fc"
  else
    page=0
    while :; do
      page=$((page + 1))
      if [ "$page" -gt "$MAX_PAGES_PER_CHAT" ]; then
        break
      fi

      encoded_cursor="$(beeper_urlencode "$cursor")"
      path="/v1/chats/${encoded_chat_id}/messages?cursor=${encoded_cursor}&direction=after"
      resp="$(beeper_get "$path")" || { rm -f "$items_tmp"; return 1; }
      if [ -z "$resp" ]; then
        rm -f "$items_tmp"
        return 1
      fi

      printf '%s' "$resp" | jq -c '.items[]?' >> "$items_tmp"

      fc="$(printf '%s' "$resp" | jq -r '.newestCursor // empty')"
      if [ -n "$fc" ]; then
        final_cursor="$fc"
        cursor="$fc"
      fi

      has_more="$(printf '%s' "$resp" | jq -r '.hasMore // false')"
      if [ "$has_more" != "true" ]; then
        break
      fi
    done
  fi

  jq -cs --arg fc "$final_cursor" '{items: ., finalCursor: $fc}' "$items_tmp"
  rm -f "$items_tmp"
}

# ---------------------------------------------------------------------------
# fetch_backfill_messages <chatID> [start-cursor] <window-start-ISO> —
# --backfill mode only (plan 24 U6). Paginates backward (direction=before)
# from [start-cursor] (the chat's existing *incremental* cursor, passed in
# by the caller — never read from here) or, with no start-cursor, from the
# newest page (chat's first-ever capture, incremental or backfill). Stops
# once a page's oldest message predates window-start, once the API reports
# no more history, or after $MAX_PAGES_PER_CHAT pages (remainder is simply
# not reached this one-shot run — no resume bookkeeping, per D4). Messages
# older than window-start within a straddling page are filtered out. Emits
# one JSON object on stdout: {items: [Message, …], finalCursor: "<oldest
# cursor reached, or the input start-cursor if no page was fetched>"}.
# Returns 1 on a beeper_get failure.
# ---------------------------------------------------------------------------
fetch_backfill_messages() {
  chat_id="$1"
  cursor="${2:-}"
  window_start="$3"

  encoded_chat_id="$(beeper_urlencode "$chat_id")"
  items_tmp="$(mktemp)"
  final_cursor="$cursor"
  page=0

  while :; do
    page=$((page + 1))
    if [ "$page" -gt "$MAX_PAGES_PER_CHAT" ]; then
      break
    fi

    if [ -z "$cursor" ]; then
      path="/v1/chats/${encoded_chat_id}/messages"
    else
      encoded_cursor="$(beeper_urlencode "$cursor")"
      path="/v1/chats/${encoded_chat_id}/messages?cursor=${encoded_cursor}&direction=before"
    fi

    resp="$(beeper_get "$path")" || { rm -f "$items_tmp"; return 1; }
    if [ -z "$resp" ]; then
      rm -f "$items_tmp"
      return 1
    fi

    # Keep only messages at/after window-start — a page may straddle it.
    printf '%s' "$resp" | jq -c --arg ws "$window_start" \
      '.items[]? | select(.timestamp >= $ws)' >> "$items_tmp"

    oldest_ts="$(printf '%s' "$resp" | jq -r '[.items[].timestamp] | min // empty' 2>/dev/null)"
    oldest_cursor="$(printf '%s' "$resp" | jq -r '.oldestCursor // .cursors.oldest // empty')"
    has_more="$(printf '%s' "$resp" | jq -r '.hasMore // false')"

    [ -n "$oldest_cursor" ] && final_cursor="$oldest_cursor"

    if [ -n "$oldest_ts" ] && [ "$oldest_ts" \< "$window_start" ]; then
      break
    fi

    if [ "$has_more" != "true" ] || [ -z "$oldest_cursor" ]; then
      break
    fi

    cursor="$oldest_cursor"
  done

  jq -cs --arg fc "$final_cursor" '{items: ., finalCursor: $fc}' "$items_tmp"
  rm -f "$items_tmp"
}
