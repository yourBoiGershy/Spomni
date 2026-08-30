#!/bin/bash
# beeper-send.sh — the self-only Beeper send lane.
#
# Usage:
#   beeper-send.sh <store-dir> [--text-file <f>] [--chat-id <id>]
#                  [--reminder <iso>] [--notify-reminder [--reminder-at <iso>]]
#                  [--private-data-root <p>]
#
# At least one of --text-file / --notify-reminder is required.
#
# Posts the contents of <f> (a rendered nudge, already drafted by another
# package) as a text message to the user's own Beeper "Note to self" chat,
# via the local Beeper Desktop/Server Client API. This is the one send this
# repo ever performs on the user's behalf, and it is only ever addressed to
# the user themselves — `docs/DECISIONS.md#notify-self-is-a-send`. It never
# sends to any other chat id; the only source of truth for the destination
# chat is `<store-dir>/profile.md`'s `## Notify` section
# (`packages/core/contracts/profile.md` 1.1.0), never a caller-supplied
# default.
#
# Config/token resolution is delegated to beeper-in's shared lib.sh
# (`beeper_load_config`) — same data dir, same skip-disabled/skip-no-token
# semantics as the beeper-in sweep. This package never writes or copies
# beeper-in's token/config; it only reads them.
#
# <private-data-root> (--private-data-root, or --store-dir/../.. by
# default, matching the `data/{store,connectors}` layout documented in
# docs/data-layout.md — <private-data-root>/data/store is the store dir,
# <private-data-root>/data/connectors/beeper-in is beeper-in's data dir)
# is used to build the beeper-in data dir passed to beeper_load_config:
# `<private-data-root>/data/connectors/beeper-in`.
#
# Exit codes:
#   0  sent (or a clean skip: skip-disabled / skip-no-token)
#   4  refuse — no beeper_chat_id in profile.md's ## Notify, or a
#      --chat-id argument that does not match the profile's resolved id.
#      Zero HTTP calls happen on any refusal path.
#   5  send-failed — the messages/reminders POST failed (transport error or
#      non-success response)
#
# --reminder <iso>: after a successful send, also POST a reminder for the
# same chat at the given ISO-8601 timestamp (explicit set, no keep-check).
# The Reminder POST body shape below is Beeper's documented
# `{"reminder":{"remindAt":"<iso>"}}` convention — verified live 2026-08-30
# (plan 33 D5b): `GET /v1/chats/{id}` returns
# `{"reminder":{"remindAt":"<iso>","dismissOnIncomingMessage":false}, ...}`
# (or `reminder: null`); one reminder per chat, a new POST replaces it.
#
# --notify-reminder: a post to the note-to-self chat is the user's own
# outgoing message, so Beeper never notifies on it — the only thing that
# rings is the chat reminder (plan 33 D5b). GET the chat's current reminder;
# if it has a `remindAt` later than now (UTC) — i.e. the user set their own
# future reminder — leave it alone and print "reminder kept (user)
# at=<iso>". Otherwise (no reminder, or one already in the past) POST a new
# reminder at now (UTC), or at --reminder-at <iso> if given, and print
# "reminder set at=<iso>". Independent of --text-file: usable standalone
# (deliver-tick.sh's post-tick call) or alongside a send.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

BEEPER_IN_LIB="${REPO_ROOT}/packages/connectors/beeper-in/scripts/lib.sh"
OUT_LIB="${SCRIPT_DIR}/lib.sh"

# shellcheck source=packages/connectors/beeper-in/scripts/lib.sh
. "$BEEPER_IN_LIB"
# shellcheck source=packages/connectors/beeper-out/scripts/lib.sh
. "$OUT_LIB"

usage() {
  echo "usage: beeper-send.sh <store-dir> [--text-file <f>] [--chat-id <id>] [--reminder <iso>] [--notify-reminder [--reminder-at <iso>]] [--private-data-root <p>]" >&2
  exit 1
}

STORE_DIR="${1:-}"
[ -z "$STORE_DIR" ] && usage
shift

TEXT_FILE=""
CHAT_ID_ARG=""
REMINDER_ISO=""
NOTIFY_REMINDER=""
REMINDER_AT_ARG=""
PRIVATE_DATA_ROOT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --text-file)
      TEXT_FILE="${2:-}"
      shift 2
      ;;
    --chat-id)
      CHAT_ID_ARG="${2:-}"
      shift 2
      ;;
    --reminder)
      REMINDER_ISO="${2:-}"
      shift 2
      ;;
    --notify-reminder)
      NOTIFY_REMINDER=1
      shift
      ;;
    --reminder-at)
      REMINDER_AT_ARG="${2:-}"
      shift 2
      ;;
    --private-data-root)
      PRIVATE_DATA_ROOT="${2:-}"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

if [ -z "$TEXT_FILE" ] && [ -z "$NOTIFY_REMINDER" ]; then
  usage
fi
if [ -n "$TEXT_FILE" ] && [ ! -f "$TEXT_FILE" ]; then
  echo "beeper-send: no such text file: ${TEXT_FILE}" >&2
  exit 1
fi

case "$STORE_DIR" in
  /*) STORE_DIR_ABS="$STORE_DIR" ;;
  *) STORE_DIR_ABS="$(cd "$STORE_DIR" 2>/dev/null && pwd)" ;;
esac
if [ -z "${STORE_DIR_ABS:-}" ]; then
  echo "beeper-send: no such store dir: ${STORE_DIR}" >&2
  exit 1
fi

if [ -z "$PRIVATE_DATA_ROOT" ]; then
  PRIVATE_DATA_ROOT="$(cd "${STORE_DIR_ABS}/../.." 2>/dev/null && pwd)"
fi
if [ -z "$PRIVATE_DATA_ROOT" ]; then
  echo "beeper-send: could not resolve private data root from store dir ${STORE_DIR_ABS}" >&2
  exit 1
fi

BEEPER_IN_DATA_DIR="${PRIVATE_DATA_ROOT}/data/connectors/beeper-in"

beeper_load_config "$BEEPER_IN_DATA_DIR"
load_rc=$?

case "$load_rc" in
  2)
    echo "skip-disabled"
    exit 0
    ;;
  3)
    echo "skip-no-token"
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# Resolve beeper_chat_id from <store-dir>/profile.md's `## Notify` section
# (packages/core/contracts/profile.md 1.1.0). Bullet shape:
#   - **[stated-by-user]** beeper_chat_id: 1 (2026-08-30)
# Strip the provenance tag, the key, and any trailing "(date)". No section
# or no key -> refuse (exit 4), zero HTTP calls.
# ---------------------------------------------------------------------------
PROFILE_FILE="${STORE_DIR_ABS}/profile.md"

RESOLVED_CHAT_ID=""
if [ -f "$PROFILE_FILE" ]; then
  notify_section="$(awk '/^## Notify$/{flag=1;next} /^## /{flag=0} flag' "$PROFILE_FILE")"
  notify_line="$(printf '%s\n' "$notify_section" | grep -m1 -E '^- \*\*\[stated-by-user\]\*\* beeper_chat_id:' || true)"
  if [ -n "$notify_line" ]; then
    RESOLVED_CHAT_ID="$(printf '%s\n' "$notify_line" | sed -E 's/.*beeper_chat_id:[[:space:]]*//; s/[[:space:]]*\([0-9-]+\)[[:space:]]*$//')"
  fi
fi

if [ -z "$RESOLVED_CHAT_ID" ]; then
  echo "refuse: no beeper_chat_id in profile ## Notify" >&2
  exit 4
fi

if [ -n "$CHAT_ID_ARG" ] && [ "$CHAT_ID_ARG" != "$RESOLVED_CHAT_ID" ]; then
  echo "refuse: chat id not in profile ## Notify" >&2
  exit 4
fi

CHAT_ID="$RESOLVED_CHAT_ID"
ENCODED_CHAT_ID="$(beeper_urlencode "$CHAT_ID")"

if [ -n "$TEXT_FILE" ]; then
  # -------------------------------------------------------------------------
  # Send: POST /v1/chats/<id>/messages {"text": <file contents>}
  # -------------------------------------------------------------------------
  MESSAGE_TEXT_JSON="$(jq -Rs '.' "$TEXT_FILE")"
  SEND_BODY="$(jq -cn --argjson text "$MESSAGE_TEXT_JSON" '{text: $text}')"

  send_resp="$(beeper_post "/v1/chats/${ENCODED_CHAT_ID}/messages" "$SEND_BODY")"
  send_rc=$?

  if [ "$send_rc" -ne 0 ] || [ -z "$send_resp" ]; then
    echo "send-failed chat=${CHAT_ID} reason=transport-error" >&2
    exit 5
  fi

  send_error="$(printf '%s' "$send_resp" | jq -r '.error // .message // empty' 2>/dev/null)"
  if [ -n "$send_error" ]; then
    echo "send-failed chat=${CHAT_ID} reason=${send_error}" >&2
    exit 5
  fi

  message_id="$(printf '%s' "$send_resp" | jq -r '.id // .messageID // .pendingMessageID // empty' 2>/dev/null)"
  [ -z "$message_id" ] && message_id="-"

  echo "sent chat=${CHAT_ID} message_id=${message_id}"

  # -------------------------------------------------------------------------
  # Optional reminder: POST /v1/chats/<id>/reminders
  # {"reminder":{"remindAt":"<iso>"}} — explicit set, no keep-check.
  # -------------------------------------------------------------------------
  if [ -n "$REMINDER_ISO" ]; then
    REMINDER_BODY="$(jq -cn --arg at "$REMINDER_ISO" '{reminder: {remindAt: $at}}')"
    reminder_resp="$(beeper_post "/v1/chats/${ENCODED_CHAT_ID}/reminders" "$REMINDER_BODY")"
    reminder_rc=$?

    if [ "$reminder_rc" -ne 0 ]; then
      echo "send-failed chat=${CHAT_ID} reason=reminder-transport-error" >&2
      exit 5
    fi

    reminder_error="$(printf '%s' "$reminder_resp" | jq -r '.error // .message // empty' 2>/dev/null)"
    if [ -n "$reminder_error" ]; then
      echo "send-failed chat=${CHAT_ID} reason=reminder-${reminder_error}" >&2
      exit 5
    fi

    echo "reminder chat=${CHAT_ID} at=${REMINDER_ISO}"
  fi
fi

# ---------------------------------------------------------------------------
# --notify-reminder: a post to the note-to-self chat is the user's own
# outgoing message, so Beeper never notifies on it — the only thing that
# rings is the chat reminder (plan 33 D5b). GET the chat's current reminder
# first; keep it if the user already set a future one, otherwise (re)set it
# to now (or --reminder-at, if given). See header note for the verified
# GET/POST shapes.
# ---------------------------------------------------------------------------
if [ -n "$NOTIFY_REMINDER" ]; then
  chat_resp="$(beeper_get_json "/v1/chats/${ENCODED_CHAT_ID}")"
  chat_rc=$?

  if [ "$chat_rc" -ne 0 ] || [ -z "$chat_resp" ]; then
    echo "send-failed chat=${CHAT_ID} reason=reminder-get-transport-error" >&2
    exit 5
  fi

  chat_error="$(printf '%s' "$chat_resp" | jq -r '.error // .message // empty' 2>/dev/null)"
  if [ -n "$chat_error" ]; then
    echo "send-failed chat=${CHAT_ID} reason=reminder-get-${chat_error}" >&2
    exit 5
  fi

  current_remind_at="$(printf '%s' "$chat_resp" | jq -r '.reminder.remindAt // empty' 2>/dev/null)"
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  target_iso="${REMINDER_AT_ARG:-$now_iso}"

  # iso_to_epoch <iso> — portable ISO-8601 (optionally millisecond-precision,
  # Z-suffixed) -> epoch seconds, GNU date first then BSD date. Empty output
  # (no epoch) if unparsable.
  iso_to_epoch() {
    stripped="$(printf '%s' "$1" | sed -E 's/\.[0-9]+Z$/Z/')"
    date -u -d "$stripped" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$stripped" +%s 2>/dev/null
  }

  KEEP_EXISTING=0
  if [ -n "$current_remind_at" ]; then
    current_epoch="$(iso_to_epoch "$current_remind_at")"
    now_epoch="$(iso_to_epoch "$now_iso")"
    if [ -n "$current_epoch" ] && [ -n "$now_epoch" ] && [ "$current_epoch" -gt "$now_epoch" ]; then
      KEEP_EXISTING=1
    fi
  fi

  if [ "$KEEP_EXISTING" -eq 1 ]; then
    echo "reminder kept (user) at=${current_remind_at}"
  else
    REMINDER_BODY="$(jq -cn --arg at "$target_iso" '{reminder: {remindAt: $at}}')"
    reminder_resp="$(beeper_post "/v1/chats/${ENCODED_CHAT_ID}/reminders" "$REMINDER_BODY")"
    reminder_rc=$?

    if [ "$reminder_rc" -ne 0 ]; then
      echo "send-failed chat=${CHAT_ID} reason=reminder-transport-error" >&2
      exit 5
    fi

    reminder_error="$(printf '%s' "$reminder_resp" | jq -r '.error // .message // empty' 2>/dev/null)"
    if [ -n "$reminder_error" ]; then
      echo "send-failed chat=${CHAT_ID} reason=reminder-${reminder_error}" >&2
      exit 5
    fi

    echo "reminder set at=${target_iso}"
  fi
fi

exit 0
