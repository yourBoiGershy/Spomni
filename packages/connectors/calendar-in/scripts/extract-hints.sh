#!/bin/bash
# extract-hints.sh — event JSON on stdin -> one participant-hint line per
# organizer, creator, and attendee, in that order.
#
# Usage:
#   extract-hints.sh < event.json
#
# One line of output per participant, "Name <email>" form when both a
# displayName and email are present, bare email when only an email is
# present, bare name when only a name is present. Organizer and creator
# are each emitted as their own line (even when they are the same person,
# or also appear inside attendees with organizer: true) — duplicates
# across organizer/creator/attendees are expected and are NOT deduplicated
# here. The user's own address (an attendee with self: true) is never
# filtered out.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -eu

if ! command -v jq >/dev/null 2>&1; then
  echo "extract-hints.sh: jq is required" >&2
  exit 1
fi

EVENT_JSON="$(cat)"

# format_hint: given displayName and email (either may be empty string),
# print the appropriate hint line. Called via jq itself below so the
# formatting logic lives in one place (jq's own conditional), applied
# uniformly to organizer, creator, and every attendee.
format_participants() {
  printf '%s' "$EVENT_JSON" | jq -r '
    def fmt:
      if (.displayName // "") != "" and (.email // "") != "" then
        "\(.displayName) <\(.email)>"
      elif (.email // "") != "" then
        .email
      elif (.displayName // "") != "" then
        .displayName
      else
        empty
      end;
    ( [.organizer] + [.creator] + (.attendees // []) )
    | .[]
    | select(. != null)
    | fmt
  '
}

format_participants
