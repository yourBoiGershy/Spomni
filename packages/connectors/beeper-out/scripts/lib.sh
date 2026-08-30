# lib.sh — shared library for the beeper-out (self-notify) send lane.
#
# Sourced by beeper-send.sh (and tests). Provides:
#   beeper_post <path> <json>  — the ONLY HTTP call site in this sub-package,
#                                 POST-only, the mirror image of beeper-in's
#                                 GET-only beeper_get
#
# Config loading (beeper_load_config), token handling, and beeper_urlencode
# are NOT duplicated here — this package sources beeper-in's
# scripts/lib.sh directly (read-only reuse of its config/token resolution;
# never copies the token or config elsewhere, per package.md's Consumes).
#
# Allowed paths for beeper_post: /v1/chats/*/messages,
# /v1/chats/*/reminders — both write endpoints, both scoped to the single
# chat id resolved from data/store/profile.md's `## Notify` section
# (never any other chat).
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile,
# no ${var,,}.
#
# Not meant to be executed directly — `source` this file.

# ---------------------------------------------------------------------------
# beeper_post <path> <json> — the ONLY HTTP call site in this sub-package.
# POST only, curl -sS --max-time 15, Content-Type: application/json, Bearer
# auth from $BEEPER_TOKEN (set by beeper-in's beeper_load_config, sourced by
# the caller before this is used). When $BEEPER_HTTP_STUB is set, execs that
# stub as `"$BEEPER_HTTP_STUB" POST "$path" "$json"` instead of curl (stub
# prints a body to stdout, exits curl-style) so tests run fully offline.
# Prints the response body to stdout; returns curl's / the stub's exit
# status (non-zero on transport failure).
# ---------------------------------------------------------------------------
beeper_post() {
  path="$1"
  json="$2"

  if [ -n "${BEEPER_HTTP_STUB:-}" ]; then
    "$BEEPER_HTTP_STUB" POST "$path" "$json"
    return $?
  fi

  curl -sS --max-time 15 -X POST \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${BEEPER_TOKEN}" \
    --data "$json" \
    "${BASE_URL}${path}"
}
