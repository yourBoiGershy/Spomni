#!/bin/bash
# deliver-tick.sh — the idempotent delivery step: turns every not-yet-
# delivered fired wake-up batch into one rendered message, written to the
# outbox and sent through the configured channel.
#
# Usage:
#   deliver-tick.sh <store-dir> [--today YYYY-MM-DD] [--now <ISO local
#                    datetime>] [--private-data-root <p>]
#
# Mission test (docs/USE-CASES.md): cuts *remembering-to* by turning a fired
# batch into a delivered nudge without the user having to go find it; never
# substitutes for the human — the human still sends every reply, this script
# only delivers the assistant's own draft nudge card to the user themselves.
# Quiet hours are respected; no guilt surface here (render-nudge-cards.sh
# owns that — this script never compares batch age).
#
# Algorithm:
#   1. List <store-dir>/wakeups/fired/*-batch.json (basenames), subtract
#      names already present in column 1 of <store-dir>/outbox/delivered.log
#      (absent file == nothing delivered yet; the outbox dir itself is
#      created lazily, only when something is actually written). No new
#      batches -> "deliver: nothing new", exit 0.
#   2. Resolve the delivery channel from profile.md's `## Notify` section
#      (packages/core/contracts/profile.md 1.1.0) `channel:` bullet. Absent
#      -> beeper-self if <private-data-root>/data/connectors/beeper-in/
#      config.json AND its token file both exist, else gmail-self (mirrors
#      the contract's own resolution rule). Prints "deliver: channel=<c>".
#   3. Quiet hours: if `## Notify`'s `quiet_hours: HH:MM-HH:MM` bullet is
#      set, compare against --now (default: current local HH:MM). The
#      window may wrap midnight (22:00-08:00 holds at 23:30 and 07:30, not
#      at 09:00). Inside the window -> "deliver: quiet-hours hold n=<k>",
#      exit 0, nothing written, nothing logged (next tick re-examines the
#      same batches).
#   4. Per new batch, oldest first (sort by filename — batch names are
#      timestamp-prefixed):
#        a. render-nudge-cards.sh -> tmp text file.
#           - exit 3 (empty entries): "deliver: empty batch <name>", append
#             `<name>\tnone\t<ts>\t-` to delivered.log (so it is never
#             re-examined), continue to the next batch (nothing to file or
#             send).
#           - exit 0: continue below.
#        b. file-out.sh <store> --text-file <tmp> --batch <batch> — always,
#           regardless of channel (the contract's outbox-is-always-an-
#           audit-trail rule). Captures the outbox path.
#        c. Route by channel:
#           - beeper-self: beeper-send.sh.
#             - exit 0, "sent ...": `<name>\tbeeper-self\t<ts>\t<message_id>`
#             - exit 0, skip-disabled/skip-no-token: outbox-only line
#               `<name>\toutbox\t<ts>\t<outbox path>` +
#               "deliver: beeper skipped (<reason>), outbox only"
#             - exit 4 (refuse): same outbox-only line + the refuse line
#             - exit 5 (send-failed): "deliver: send-failed <name>", NO log
#               line (retried next tick), continue; final exit becomes 1
#           - gmail-self: copy the rendered text to
#             <store>/outbox/pending-gmail/<name>.txt, print
#             "deliver: gmail-self pending (session) <name>" — no log line
#             (a human/claude session drains pending-gmail/ and sends via
#             the gmail connector; not this script's job).
#           - outbox: `<name>\toutbox\t<ts>\t<path>`
#           - none: `<name>\tnone\t<ts>\t-`
#   5. Log lines are appended only after the adapter reported success.
#      <ts> = date -u +%Y-%m-%dT%H:%M:%SZ. Every terminal state prints a
#      distinct line — silence is never a valid outcome. Exit 0 on
#      skips/holds; exit 1 only on a genuine transport failure
#      (send-failed). A final summary line is always printed on the normal
#      (non-early-exit) path:
#        deliver: done sent=<a> outbox=<b> pending=<c> held=<d>
#      sent = beeper-self successes; outbox = batches whose only recorded
#      delivery is the outbox file (skip/refuse-fallback or channel=outbox);
#      pending = gmail-self hand-offs; held = channel=none batches (filed to
#      the outbox audit trail but not actively delivered this run).
#   6. On-demand drafts (plan 34's `<n> draft` reply, written by ingestion's
#      feedback-parse.sh to <store-dir>/outbox/drafts/<batch-name>-<n>-
#      draft.txt — first line `Draft (unsent):`, then the draft text or
#      `no draft available for <n>`): after the batch loop, subject to the
#      same quiet-hours hold, every draft file not yet in delivered.log's
#      column 1 is filed to the outbox audit trail (file-out.sh, always) and
#      routed through the same channel as a batch (beeper-self send,
#      gmail-self pending copy, outbox/none log-only). Delivered.log rows
#      use `draft:<channel>` in column 2. Log lines: "deliver: draft sent
#      <file>", "deliver: draft pending (session) <file>", "deliver: draft
#      send-failed <file>" (retried next tick, no log line, sets the final
#      exit to 1 like a failed batch send). The final summary line gets a
#      trailing `drafts=<k>` counting every draft that reached a terminal
#      non-failed state this run.
#   7. Reminder (plan 33 D5b): after the batch loop and the draft loop, if
#      at least one beeper-self send succeeded this tick (batch or draft),
#      call beeper-send.sh once (not per message) with `--notify-reminder
#      --private-data-root <p>` so the note-to-self chat's reminder rings —
#      Beeper never notifies on the user's own outgoing message, only the
#      chat reminder does. Its stdout line is logged prefixed `deliver: `.
#      A non-zero exit is logged `deliver: reminder failed (exit n)` and
#      does NOT change the tick's own exit status.
#
# jq resolution: launchd's PATH is the minimal
# /usr/bin:/bin:/usr/sbin:/sbin, which usually has no jq. Resolve it via
# command -v, then the two common Homebrew locations, then export PATH with
# jq's directory appended so the plain `jq` calls inside render-nudge-
# cards.sh / file-out.sh / beeper-send.sh / beeper-in's lib.sh also resolve
# it (same approach as packages/connectors/beeper-in/scripts/beeper-sweep.sh
# and lib.sh use for their own jq calls).
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -u

SCRIPT_NAME="deliver-tick.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

RENDER_SCRIPT="${REPO_ROOT}/packages/core/scripts/render-nudge-cards.sh"
FILE_OUT_SCRIPT="${REPO_ROOT}/packages/connectors/file-out/scripts/file-out.sh"
BEEPER_SEND_SCRIPT="${REPO_ROOT}/packages/connectors/beeper-out/scripts/beeper-send.sh"

usage() {
  echo "usage: ${SCRIPT_NAME} <store-dir> [--today YYYY-MM-DD] [--now <ISO local datetime>] [--private-data-root <p>]" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# jq resolution for launchd's minimal PATH (see header comment).
# ---------------------------------------------------------------------------
JQ_BIN=""
if command -v jq >/dev/null 2>&1; then
  JQ_BIN="$(command -v jq)"
elif [ -x /opt/homebrew/bin/jq ]; then
  JQ_BIN=/opt/homebrew/bin/jq
elif [ -x /usr/local/bin/jq ]; then
  JQ_BIN=/usr/local/bin/jq
fi
if [ -z "$JQ_BIN" ]; then
  echo "${SCRIPT_NAME}: jq not found (checked PATH, /opt/homebrew/bin, /usr/local/bin)" >&2
  exit 2
fi
JQ_DIR="$(dirname "$JQ_BIN")"
case ":${PATH}:" in
  *":${JQ_DIR}:"*) ;;
  *) PATH="${PATH}:${JQ_DIR}" ;;
esac
export PATH

STORE_DIR="${1:-}"
[ -z "$STORE_DIR" ] && usage
shift

TODAY=""
NOW_ARG=""
PRIVATE_DATA_ROOT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --today)
      TODAY="${2:-}"
      shift 2
      ;;
    --now)
      NOW_ARG="${2:-}"
      shift 2
      ;;
    --private-data-root)
      PRIVATE_DATA_ROOT="${2:-}"
      shift 2
      ;;
    *)
      echo "${SCRIPT_NAME}: unrecognized argument: $1" >&2
      usage
      ;;
  esac
done

case "$STORE_DIR" in
  /*) STORE_DIR_ABS="$STORE_DIR" ;;
  *) STORE_DIR_ABS="$(cd "$STORE_DIR" 2>/dev/null && pwd)" ;;
esac
if [ -z "${STORE_DIR_ABS:-}" ]; then
  echo "${SCRIPT_NAME}: no such store dir: ${STORE_DIR}" >&2
  exit 2
fi

if [ -z "$PRIVATE_DATA_ROOT" ]; then
  PRIVATE_DATA_ROOT="$(cd "${STORE_DIR_ABS}/../.." 2>/dev/null && pwd)"
fi

FIRED_DIR="${STORE_DIR_ABS}/wakeups/fired"
OUTBOX_DIR="${STORE_DIR_ABS}/outbox"
DELIVERED_LOG="${OUTBOX_DIR}/delivered.log"
PROFILE_FILE="${STORE_DIR_ABS}/profile.md"

CLEANUP_TMPS=""
cleanup() {
  # shellcheck disable=SC2086
  [ -n "$CLEANUP_TMPS" ] && rm -f $CLEANUP_TMPS
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Step 1: list not-yet-delivered fired batches.
# ---------------------------------------------------------------------------
ALL_TMP="$(mktemp)"
DELIVERED_NAMES_TMP="$(mktemp)"
NEW_TMP="$(mktemp)"
CLEANUP_TMPS="${CLEANUP_TMPS} ${ALL_TMP} ${DELIVERED_NAMES_TMP} ${NEW_TMP}"

if [ -d "$FIRED_DIR" ]; then
  find "$FIRED_DIR" -maxdepth 1 -type f -name '*-batch.json' -exec basename {} \; 2>/dev/null | sort > "$ALL_TMP"
else
  : > "$ALL_TMP"
fi

if [ -f "$DELIVERED_LOG" ]; then
  cut -f1 "$DELIVERED_LOG" 2>/dev/null | sort -u > "$DELIVERED_NAMES_TMP"
else
  : > "$DELIVERED_NAMES_TMP"
fi

comm -23 "$ALL_TMP" "$DELIVERED_NAMES_TMP" > "$NEW_TMP"

NEW_COUNT="$(wc -l < "$NEW_TMP" | tr -d ' ')"

# ---------------------------------------------------------------------------
# Step 1b: list not-yet-delivered on-demand draft files (written by
# ingestion's feedback-parse.sh on a `<n> draft` reply):
#   <store-dir>/outbox/drafts/<batch-name>-<n>-draft.txt
# Same delivered.log (column 1 matches the draft file's basename) covers
# idempotency for drafts too.
# ---------------------------------------------------------------------------
DRAFTS_DIR="${OUTBOX_DIR}/drafts"
DRAFT_ALL_TMP="$(mktemp)"
DRAFT_NEW_TMP="$(mktemp)"
CLEANUP_TMPS="${CLEANUP_TMPS} ${DRAFT_ALL_TMP} ${DRAFT_NEW_TMP}"

if [ -d "$DRAFTS_DIR" ]; then
  find "$DRAFTS_DIR" -maxdepth 1 -type f -name '*-draft.txt' -exec basename {} \; 2>/dev/null | sort > "$DRAFT_ALL_TMP"
else
  : > "$DRAFT_ALL_TMP"
fi

comm -23 "$DRAFT_ALL_TMP" "$DELIVERED_NAMES_TMP" > "$DRAFT_NEW_TMP"
DRAFT_COUNT="$(wc -l < "$DRAFT_NEW_TMP" | tr -d ' ')"

if [ "$NEW_COUNT" -eq 0 ] && [ "$DRAFT_COUNT" -eq 0 ]; then
  echo "deliver: nothing new"
  exit 0
fi

# ---------------------------------------------------------------------------
# notify_get <key> — extract a `## Notify` bullet's value:
#   - **[stated-by-user]** <key>: <value> (<YYYY-MM-DD>)
# Empty output (and non-zero return) if the section or the key is absent.
# ---------------------------------------------------------------------------
NOTIFY_SECTION=""
if [ -f "$PROFILE_FILE" ]; then
  NOTIFY_SECTION="$(awk '/^## Notify$/{flag=1;next} /^## /{flag=0} flag' "$PROFILE_FILE")"
fi

notify_get() {
  key="$1"
  line="$(printf '%s\n' "$NOTIFY_SECTION" | grep -m1 -E "^- \\*\\*\\[stated-by-user\\]\\*\\* ${key}:" || true)"
  [ -z "$line" ] && return 1
  printf '%s\n' "$line" | sed -E "s/.*${key}:[[:space:]]*//; s/[[:space:]]*\([0-9-]+\)[[:space:]]*\$//"
}

# ---------------------------------------------------------------------------
# Step 2: resolve the channel.
# ---------------------------------------------------------------------------
CHANNEL="$(notify_get channel 2>/dev/null || true)"
if [ -z "$CHANNEL" ]; then
  if [ -f "${PRIVATE_DATA_ROOT}/data/connectors/beeper-in/config.json" ] && \
     [ -f "${PRIVATE_DATA_ROOT}/data/connectors/beeper-in/token" ]; then
    CHANNEL="beeper-self"
  else
    CHANNEL="gmail-self"
  fi
fi
echo "deliver: channel=${CHANNEL}"

# ---------------------------------------------------------------------------
# Step 3: quiet hours (window may wrap midnight).
# ---------------------------------------------------------------------------
hhmm_to_min() {
  h="${1%%:*}"
  m="${1##*:}"
  h=$((10#$h))
  m=$((10#$m))
  echo $((h * 60 + m))
}

QUIET_HOURS="$(notify_get quiet_hours 2>/dev/null || true)"
if [ -n "$QUIET_HOURS" ]; then
  QH_START="${QUIET_HOURS%%-*}"
  QH_END="${QUIET_HOURS##*-}"

  if [ -n "$NOW_ARG" ]; then
    NOW_HHMM="${NOW_ARG##*T}"
  else
    NOW_HHMM="$(date +%H:%M)"
  fi
  NOW_HHMM="${NOW_HHMM%%:*}:$(printf '%s' "${NOW_HHMM#*:}" | cut -c1-2)"

  s_min="$(hhmm_to_min "$QH_START")"
  e_min="$(hhmm_to_min "$QH_END")"
  n_min="$(hhmm_to_min "$NOW_HHMM")"

  IN_QUIET=0
  if [ "$s_min" -le "$e_min" ]; then
    if [ "$n_min" -ge "$s_min" ] && [ "$n_min" -lt "$e_min" ]; then
      IN_QUIET=1
    fi
  else
    if [ "$n_min" -ge "$s_min" ] || [ "$n_min" -lt "$e_min" ]; then
      IN_QUIET=1
    fi
  fi

  if [ "$IN_QUIET" -eq 1 ]; then
    echo "deliver: quiet-hours hold n=$((NEW_COUNT + DRAFT_COUNT))"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Step 4: per new batch, oldest first.
# ---------------------------------------------------------------------------
SENT_COUNT=0
OUTBOX_COUNT=0
PENDING_COUNT=0
HELD_COUNT=0
FAILED=0

RENDER_TMP="$(mktemp)"
ERR_TMP="$(mktemp)"
CLEANUP_TMPS="${CLEANUP_TMPS} ${RENDER_TMP} ${ERR_TMP}"

while IFS= read -r name; do
  [ -z "$name" ] && continue
  batch_path="${FIRED_DIR}/${name}"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  render_args=("$batch_path")
  [ -n "$TODAY" ] && render_args=("$batch_path" --today "$TODAY")

  "$RENDER_SCRIPT" "${render_args[@]}" > "$RENDER_TMP" 2>"$ERR_TMP"
  render_rc=$?

  if [ "$render_rc" -eq 3 ]; then
    echo "deliver: empty batch ${name}"
    mkdir -p "$OUTBOX_DIR"
    printf '%s\t%s\t%s\t%s\n' "$name" "none" "$ts" "-" >> "$DELIVERED_LOG"
    continue
  fi

  if [ "$render_rc" -ne 0 ]; then
    echo "deliver: render-failed ${name}: $(cat "$ERR_TMP")" >&2
    continue
  fi

  file_out_args=("$STORE_DIR_ABS" --text-file "$RENDER_TMP" --batch "$batch_path")
  [ -n "$TODAY" ] && file_out_args=("${file_out_args[@]}" --today "$TODAY")

  file_out_line="$("$FILE_OUT_SCRIPT" "${file_out_args[@]}" 2>"$ERR_TMP")"
  file_out_rc=$?
  if [ "$file_out_rc" -ne 0 ]; then
    echo "deliver: file-out-failed ${name}: $(cat "$ERR_TMP")" >&2
    continue
  fi
  outbox_path="${file_out_line#outbox: }"

  case "$CHANNEL" in
    beeper-self)
      beeper_args=("$STORE_DIR_ABS" --text-file "$RENDER_TMP")
      [ -n "$PRIVATE_DATA_ROOT" ] && beeper_args=("${beeper_args[@]}" --private-data-root "$PRIVATE_DATA_ROOT")

      send_out="$("$BEEPER_SEND_SCRIPT" "${beeper_args[@]}" 2>"$ERR_TMP")"
      send_rc=$?
      send_err="$(cat "$ERR_TMP")"

      case "$send_rc" in
        0)
          case "$send_out" in
            sent\ *)
              message_id="${send_out##*message_id=}"
              printf '%s\t%s\t%s\t%s\n' "$name" "beeper-self" "$ts" "$message_id" >> "$DELIVERED_LOG"
              SENT_COUNT=$((SENT_COUNT + 1))
              ;;
            *)
              printf '%s\t%s\t%s\t%s\n' "$name" "outbox" "$ts" "$outbox_path" >> "$DELIVERED_LOG"
              echo "deliver: beeper skipped (${send_out}), outbox only"
              OUTBOX_COUNT=$((OUTBOX_COUNT + 1))
              ;;
          esac
          ;;
        4)
          printf '%s\t%s\t%s\t%s\n' "$name" "outbox" "$ts" "$outbox_path" >> "$DELIVERED_LOG"
          echo "deliver: ${send_err}"
          OUTBOX_COUNT=$((OUTBOX_COUNT + 1))
          ;;
        5)
          echo "deliver: send-failed ${name}"
          FAILED=1
          ;;
        *)
          echo "deliver: send-failed ${name}: unexpected exit ${send_rc}: ${send_err}"
          FAILED=1
          ;;
      esac
      ;;
    gmail-self)
      PENDING_DIR="${STORE_DIR_ABS}/outbox/pending-gmail"
      mkdir -p "$PENDING_DIR"
      cp "$RENDER_TMP" "${PENDING_DIR}/${name}.txt"
      echo "deliver: gmail-self pending (session) ${name}"
      PENDING_COUNT=$((PENDING_COUNT + 1))
      ;;
    outbox)
      printf '%s\t%s\t%s\t%s\n' "$name" "outbox" "$ts" "$outbox_path" >> "$DELIVERED_LOG"
      OUTBOX_COUNT=$((OUTBOX_COUNT + 1))
      ;;
    none)
      printf '%s\t%s\t%s\t%s\n' "$name" "none" "$ts" "-" >> "$DELIVERED_LOG"
      HELD_COUNT=$((HELD_COUNT + 1))
      ;;
  esac
done < "$NEW_TMP"

# ---------------------------------------------------------------------------
# Step 4b: per new draft file, oldest first. Same channel routing as a
# batch, but only three outcomes: sent, pending (session drains it), or
# send-failed (retried next tick — no delivered.log line). Always filed to
# the outbox audit trail via file-out.sh first, regardless of channel.
# ---------------------------------------------------------------------------
DRAFT_DONE_COUNT=0
DRAFT_SENT_COUNT=0

while IFS= read -r dname; do
  [ -z "$dname" ] && continue
  draft_path="${DRAFTS_DIR}/${dname}"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  file_out_args=("$STORE_DIR_ABS" --text-file "$draft_path" --batch "$dname")
  [ -n "$TODAY" ] && file_out_args=("${file_out_args[@]}" --today "$TODAY")

  file_out_line="$("$FILE_OUT_SCRIPT" "${file_out_args[@]}" 2>"$ERR_TMP")"
  file_out_rc=$?
  if [ "$file_out_rc" -ne 0 ]; then
    echo "deliver: file-out-failed ${dname}: $(cat "$ERR_TMP")" >&2
    continue
  fi
  draft_outbox_path="${file_out_line#outbox: }"

  case "$CHANNEL" in
    beeper-self)
      beeper_args=("$STORE_DIR_ABS" --text-file "$draft_path")
      [ -n "$PRIVATE_DATA_ROOT" ] && beeper_args=("${beeper_args[@]}" --private-data-root "$PRIVATE_DATA_ROOT")

      send_out="$("$BEEPER_SEND_SCRIPT" "${beeper_args[@]}" 2>"$ERR_TMP")"
      send_rc=$?
      send_err="$(cat "$ERR_TMP")"

      case "$send_rc" in
        0)
          case "$send_out" in
            sent\ *)
              message_id="${send_out##*message_id=}"
              printf '%s\t%s\t%s\t%s\n' "$dname" "draft:beeper-self" "$ts" "$message_id" >> "$DELIVERED_LOG"
              echo "deliver: draft sent ${dname}"
              DRAFT_DONE_COUNT=$((DRAFT_DONE_COUNT + 1))
              DRAFT_SENT_COUNT=$((DRAFT_SENT_COUNT + 1))
              ;;
            *)
              echo "deliver: draft send-failed ${dname}: ${send_out}"
              FAILED=1
              ;;
          esac
          ;;
        *)
          echo "deliver: draft send-failed ${dname}: ${send_err}"
          FAILED=1
          ;;
      esac
      ;;
    gmail-self)
      PENDING_DIR="${STORE_DIR_ABS}/outbox/pending-gmail"
      mkdir -p "$PENDING_DIR"
      cp "$draft_path" "${PENDING_DIR}/${dname}.txt"
      echo "deliver: draft pending (session) ${dname}"
      DRAFT_DONE_COUNT=$((DRAFT_DONE_COUNT + 1))
      ;;
    outbox)
      printf '%s\t%s\t%s\t%s\n' "$dname" "draft:outbox" "$ts" "$draft_outbox_path" >> "$DELIVERED_LOG"
      DRAFT_DONE_COUNT=$((DRAFT_DONE_COUNT + 1))
      ;;
    none)
      printf '%s\t%s\t%s\t%s\n' "$dname" "draft:none" "$ts" "-" >> "$DELIVERED_LOG"
      DRAFT_DONE_COUNT=$((DRAFT_DONE_COUNT + 1))
      ;;
  esac
done < "$DRAFT_NEW_TMP"

# ---------------------------------------------------------------------------
# Step 7: reminder (plan 33 D5b). A post to the note-to-self chat is the
# user's own outgoing message — Beeper never notifies on it, only the chat
# reminder rings. Once per tick (not per message), only when at least one
# beeper-self send succeeded this tick.
# ---------------------------------------------------------------------------
if [ $((SENT_COUNT + DRAFT_SENT_COUNT)) -gt 0 ]; then
  reminder_args=("$STORE_DIR_ABS" --notify-reminder)
  [ -n "$PRIVATE_DATA_ROOT" ] && reminder_args=("${reminder_args[@]}" --private-data-root "$PRIVATE_DATA_ROOT")

  reminder_out="$("$BEEPER_SEND_SCRIPT" "${reminder_args[@]}" 2>"$ERR_TMP")"
  reminder_rc=$?
  if [ "$reminder_rc" -eq 0 ]; then
    echo "deliver: ${reminder_out}"
  else
    echo "deliver: reminder failed (exit ${reminder_rc})"
  fi
fi

echo "deliver: done sent=${SENT_COUNT} outbox=${OUTBOX_COUNT} pending=${PENDING_COUNT} held=${HELD_COUNT} drafts=${DRAFT_DONE_COUNT}"

if [ "$FAILED" -eq 1 ]; then
  exit 1
fi
exit 0
