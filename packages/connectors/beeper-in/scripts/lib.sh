# lib.sh — shared library for the beeper-in capture lane.
#
# Sourced by beeper-sweep.sh (and tests). Provides:
#   beeper_load_config <data_dir>  — load config.json + token, set globals
#   beeper_get <path-with-query>   — the ONLY HTTP call site in this sub-package
#   cursor_get / cursor_set        — cursors.tsv read/advance
#   coverage_floor_get / coverage_floor_set — coverage-floor.tsv read/write-once
#                                     (D6: incremental's first-capture oldest
#                                     cursor, backfill's start bound)
#   run_log / install_run_trap     — runs.log writer + EXIT-trap safety net
#   list_new_chats / fetch_new_messages — pagination helpers over /v1/chats(/*/messages)
#   fetch_backfill_messages        — --backfill mode's direction=before pagination
#                                     helper (plan 24 U6, D6 fix); reads/writes no
#                                     state of its own — cursor isolation lives in
#                                     the sweep
#   beeper_legacy_oldest_covered_ts — D6 legacy fallback: derives a chat's
#                                     oldest-covered message timestamp from its
#                                     existing inbox capture events, for chats
#                                     with no coverage-floor.tsv entry yet
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
  COVERAGE_FLOOR_FILE="${data_dir}/coverage-floor.tsv"
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
# coverage_floor_get <chatID> [file] — print the chat's recorded coverage-
# floor cursor and return 0 if found; return 1 (no output) otherwise. [file]
# defaults to $COVERAGE_FLOOR_FILE. The floor is the incremental lane's
# first-ever fetched page's *oldest* cursor (D6): written once per chat by
# beeper-sweep.sh on that chat's first successful incremental capture, never
# advanced afterward, never written or read by --backfill for anything other
# than as its start bound.
#
# Delegates to cursor_get's identical awk lookup (same last-match-wins scan);
# distinguishable from first-match only on a file with duplicate rows for one
# chatID, which coverage_floor_set's write-once contract (below) never
# produces, so the delegation is behavior-preserving for this file.
# ---------------------------------------------------------------------------
coverage_floor_get() {
  cursor_get "$1" "${2:-$COVERAGE_FLOOR_FILE}"
}

# ---------------------------------------------------------------------------
# coverage_floor_set <chatID> <cursor> [file] — append a coverage-floor row
# for chatID. Write-once by convention (D6): callers must call
# coverage_floor_get first and only invoke this when it reported absent —
# this function does not dedupe or overwrite an existing row itself, unlike
# cursor_set. [file] defaults to $COVERAGE_FLOOR_FILE.
# ---------------------------------------------------------------------------
coverage_floor_set() {
  chat_id="$1"
  cursor="$2"
  file="${3:-$COVERAGE_FLOOR_FILE}"

  printf '%s\t%s\n' "$chat_id" "$cursor" >> "$file"
}

# ---------------------------------------------------------------------------
# run_log <outcome> <chats> <events> <quarantined> [warn] [dedup] — append
# one greppable status line to runs.log per the plan's failure-posture
# format:
#   <ISO8601Z> <outcome> chats=<n> events=<n> quarantined=<n> [warn=…] [dedup=<n>]
# dedup (plan 41) is the count of normalize-capture.sh exit-3 (byte-identical
# duplicate) hits this run — omitted when zero/absent so every pre-plan-41
# call site and log line is untouched.
# Sets RUN_LOGGED=1 so install_run_trap's EXIT trap knows a line was written.
# ---------------------------------------------------------------------------
RUN_LOGGED=0

run_log() {
  outcome="$1"
  chats="$2"
  events="$3"
  quarantined="$4"
  warn="${5:-}"
  dedup="${6:-0}"

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  line="${ts} ${outcome} chats=${chats} events=${events} quarantined=${quarantined}"
  if [ -n "$warn" ]; then
    line="${line} warn=${warn}"
  fi
  if [ -n "$dedup" ] && [ "$dedup" -ne 0 ] 2>/dev/null; then
    line="${line} dedup=${dedup}"
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
#   {items: [Message, …], finalCursor: "<newestCursor or input cursor>",
#    oldestCursor: "<no-cursor path only: the fetched page's oldest cursor,
#    else empty>"}
# oldestCursor (D6) is the coverage floor beeper-sweep.sh records to
# coverage-floor.tsv on this chat's first-ever incremental capture — it is
# only meaningful on the no-cursor path (the single newest-page fetch);
# empty on the cursor path.
# Returns 1 on a beeper_get failure.
# ---------------------------------------------------------------------------
fetch_new_messages() {
  chat_id="$1"
  cursor="${2:-}"

  encoded_chat_id="$(beeper_urlencode "$chat_id")"
  items_tmp="$(mktemp)"
  final_cursor="$cursor"
  oldest_cursor=""

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
    oldest_cursor="$(printf '%s' "$resp" | jq -r '.oldestCursor // .cursors.oldest // empty')"
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

  jq -cs --arg fc "$final_cursor" --arg oc "$oldest_cursor" \
    '{items: ., finalCursor: $fc, oldestCursor: $oc}' "$items_tmp"
  rm -f "$items_tmp"
}

# ---------------------------------------------------------------------------
# beeper_legacy_oldest_covered_ts <store-dir> <chatID> — D6 legacy fallback,
# used only when a chat has no coverage-floor.tsv entry (pre-fix incremental
# capture already ran for it). Scans <store-dir>/inbox/*.md (capture-event
# 1.2.0: frontmatter, then the envelope-only body JSON verbatim after the
# second `---` line) for events whose body `chatID` matches, and prints the
# oldest `messages[].timestamp` found across all of them on stdout, return
# 0. Returns 1 (no output) if the chat has no matching prior events. The
# caller uses this as an exclusive upper bound: backfill must only surface
# messages strictly OLDER than this timestamp, since the chat's first
# incremental sweep already captured everything from this timestamp forward.
# ---------------------------------------------------------------------------
beeper_legacy_oldest_covered_ts() {
  store_dir="$1"
  chat_id="$2"
  inbox_dir="${store_dir}/inbox"

  [ -d "$inbox_dir" ] || return 1

  oldest=""
  for f in "$inbox_dir"/*.md; do
    [ -f "$f" ] || continue
    body="$(awk 'BEGIN{n=0} /^---$/{n++; next} n>=2{print}' "$f")"
    [ -z "$body" ] && continue
    body_chat_id="$(printf '%s' "$body" | jq -r '.chatID // empty' 2>/dev/null)"
    [ "$body_chat_id" != "$chat_id" ] && continue
    file_min="$(printf '%s' "$body" | jq -r '[.messages[]?.timestamp] | min // empty' 2>/dev/null)"
    [ -z "$file_min" ] && continue
    # Reject the literal string "null" and anything not shaped like an
    # ISO-8601 timestamp (conservative "YYYY-" prefix check, bash 3.2 safe).
    # An unrejected non-timestamp floor (e.g. "null") would sort lower than
    # every real ISO timestamp lexically and poison the backfill bound.
    case "$file_min" in
      [0-9][0-9][0-9][0-9]-*) ;;
      *) continue ;;
    esac
    if [ -z "$oldest" ] || [ "$file_min" \< "$oldest" ]; then
      oldest="$file_min"
    fi
  done

  [ -z "$oldest" ] && return 1
  case "$oldest" in
    [0-9][0-9][0-9][0-9]-*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$oldest"
  return 0
}

# ---------------------------------------------------------------------------
# fetch_backfill_messages <chatID> [start-cursor] <window-start-ISO> [legacy-max-ts] —
# --backfill mode only (plan 24 U6, D6 fix). Paginates backward
# (direction=before) from [start-cursor] — the chat's coverage-floor.tsv
# cursor when the caller has one (D6: the incremental lane's first-fetched
# page's *oldest* cursor, so pagination starts strictly before everything
# incremental already covered), or, with no start-cursor, from the newest
# page (a chat with no incremental capture at all yet — the pre-D6 newest-
# page behavior, still correct in that case). [legacy-max-ts], when given
# (only the caller's legacy-fallback path, chats with no coverage-floor.tsv
# entry because their first incremental capture predates this fix), is an
# exclusive upper bound: items with timestamp >= legacy-max-ts are dropped
# even from the newest page, since incremental already covered them. Stops
# once a page's oldest message predates window-start, once the API reports
# no more history, or after $MAX_PAGES_PER_CHAT pages (remainder is simply
# not reached this one-shot run — no resume bookkeeping, per D4). Messages
# older than window-start within a straddling page are filtered out. Emits
# one JSON object on stdout: {items: [Message, …], finalCursor: "<oldest
# cursor reached, or the input start-cursor if no page was fetched>",
# clamped: <true if pagination exhausted bridge history (hasMore false / no
# oldestCursor) before reaching window-start, false otherwise — a plain
# $MAX_PAGES_PER_CHAT cutoff does NOT count as clamped>, oldestTs: "<oldest
# message timestamp seen across all fetched pages, empty if none>"}.
# Returns 1 on a beeper_get failure.
# ---------------------------------------------------------------------------
fetch_backfill_messages() {
  chat_id="$1"
  cursor="${2:-}"
  window_start="$3"
  legacy_max_ts="${4:-}"

  encoded_chat_id="$(beeper_urlencode "$chat_id")"
  items_tmp="$(mktemp)"
  final_cursor="$cursor"
  page=0
  clamped=0
  last_oldest_ts=""

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
    # legacy_max_ts (legacy-fallback path only) additionally excludes
    # messages already covered by the chat's first incremental capture.
    if [ -n "$legacy_max_ts" ]; then
      printf '%s' "$resp" | jq -c --arg ws "$window_start" --arg lm "$legacy_max_ts" \
        '.items[]? | select(.timestamp >= $ws and .timestamp < $lm)' >> "$items_tmp"
    else
      printf '%s' "$resp" | jq -c --arg ws "$window_start" \
        '.items[]? | select(.timestamp >= $ws)' >> "$items_tmp"
    fi

    oldest_ts="$(printf '%s' "$resp" | jq -r '[.items[].timestamp] | min // empty' 2>/dev/null)"
    oldest_cursor="$(printf '%s' "$resp" | jq -r '.oldestCursor // .cursors.oldest // empty')"
    has_more="$(printf '%s' "$resp" | jq -r '.hasMore // false')"

    [ -n "$oldest_cursor" ] && final_cursor="$oldest_cursor"
    [ -n "$oldest_ts" ] && last_oldest_ts="$oldest_ts"

    if [ -n "$oldest_ts" ] && [ "$oldest_ts" \< "$window_start" ]; then
      break
    fi

    if [ "$has_more" != "true" ] || [ -z "$oldest_cursor" ]; then
      clamped=1
      break
    fi

    cursor="$oldest_cursor"
  done

  jq -cs --arg fc "$final_cursor" --arg clamped "$clamped" --arg ots "$last_oldest_ts" \
    '{items: ., finalCursor: $fc, clamped: ($clamped == "1"), oldestTs: $ots}' "$items_tmp"
  rm -f "$items_tmp"
}
