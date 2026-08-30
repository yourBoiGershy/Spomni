#!/bin/bash
# extract-email-body.sh — pulls one message's body from a saved gmail
# get_thread/get_message tool-result file, programmatically (jq only),
# so the calling session never reads the body into model context.
#
# Usage:
#   extract-email-body.sh <saved-result-file> <message-id>
#
# Prints, to stdout:
#   Subject: <subject>
#   <blank line>
#   <plaintextBody, verbatim>
#
# The subject line and the body are printed exactly as they appear in the
# saved file — no trimming, reformatting, or trailing-newline manipulation
# beyond what `jq -r`/`printf` naturally produce for the fields themselves.
#
# Exit 0 on success (body printed to stdout).
# Exit 1, with a stderr reason, if <message-id> is not present in the file
# (or the file/jq is unusable) — no partial output on stdout in that case.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -u

RESULT_FILE="${1:-}"
MESSAGE_ID="${2:-}"

if [ -z "$RESULT_FILE" ] || [ -z "$MESSAGE_ID" ]; then
  echo "extract-email-body.sh: usage: extract-email-body.sh <saved-result-file> <message-id>" >&2
  exit 1
fi

if [ ! -f "$RESULT_FILE" ]; then
  echo "extract-email-body.sh: no such file: $RESULT_FILE" >&2
  exit 1
fi

# The saved tool-result file may be a single message object (get_message)
# or a thread object with a messages[] array (get_thread) — try the thread
# shape first, fall back to treating the file itself as the message. Wrapped
# in first(...) so a duplicated message id (malformed/duplicated fixture or
# upstream payload) yields exactly one match instead of concatenating every
# match's Subject+body blocks.
JQ_MSG_SELECT='first(if (.messages? != null) then (.messages[] | select(.id == $mid)) else select(.id == $mid) end)'

# Existence check first (kept separate from the print below so a miss
# never emits partial "Subject: ..." output on stdout).
EXISTS="$(jq -r --arg mid "$MESSAGE_ID" "($JQ_MSG_SELECT) | .id" "$RESULT_FILE" 2>/dev/null)"

if [ -z "$EXISTS" ]; then
  echo "extract-email-body.sh: message id not found in $RESULT_FILE: $MESSAGE_ID" >&2
  exit 1
fi

# Print subject + blank line + plaintextBody verbatim, byte-for-byte, in one
# jq pass (-j: raw output, no jq-added trailing newline) — the body never
# transits a bash variable, so no command-substitution trailing-newline
# stripping ever touches it.
jq -j --arg mid "$MESSAGE_ID" \
  "($JQ_MSG_SELECT) | \"Subject: \" + (.subject // \"\") + \"\n\n\" + (.plaintextBody // \"\")" \
  "$RESULT_FILE"
