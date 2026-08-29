#!/bin/bash
# classify.sh — deterministic Gmail message typing helper for gmail-in.
#
# Usage:
#   classify.sh <subject> <from-address>
#   echo "<subject>|<from-address>" | classify.sh   (stdin fallback, same
#     '|'-joined form, used when args aren't convenient to pass from the
#     calling skill's shell context)
#
# Prints exactly one of: voice-note / linkedin-notification / email
#
# Rules (Plan 17's per-lane typing logic, `docs/plans/`, 2026-08-29
# direct-Google-lanes plan):
#   1. Subject contains the literal, case-sensitive substring "[ra]"
#      -> voice-note (highest precedence — wins even if the From address is
#      also a linkedin.com domain).
#   2. Else, From address's domain is linkedin.com or *.linkedin.com
#      -> linkedin-notification.
#   3. Else -> email (default).
#
# Deterministic, offline, no network calls. Portable to bash 3.2 (macOS
# default): no associative arrays, no mapfile.

set -u

SUBJECT="${1:-}"
FROM_ADDR="${2:-}"

if [ -z "$SUBJECT" ] && [ -z "$FROM_ADDR" ]; then
  # Fall back to stdin, '|'-joined: "<subject>|<from-address>"
  if [ ! -t 0 ]; then
    LINE="$(cat)"
    SUBJECT="${LINE%%|*}"
    FROM_ADDR="${LINE#*|}"
    if [ "$FROM_ADDR" = "$LINE" ]; then
      FROM_ADDR=""
    fi
  fi
fi

# Rule 1: literal case-sensitive "[ra]" in the subject.
case "$SUBJECT" in
  *'[ra]'*)
    echo "voice-note"
    exit 0
    ;;
esac

# Rule 2: From address domain is linkedin.com or any subdomain of it.
# Extract the domain from "Name <addr@domain>" or a bare "addr@domain" form.
ADDR="$FROM_ADDR"
case "$ADDR" in
  *'<'*'>'*)
    ADDR="${ADDR#*<}"
    ADDR="${ADDR%%>*}"
    ;;
esac
DOMAIN="${ADDR##*@}"
# Lowercase the domain for a case-insensitive match (email domains are
# case-insensitive per RFC 5321); addresses without an '@' yield an empty or
# unchanged DOMAIN and simply won't match below.
DOMAIN_LC="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]')"

case "$DOMAIN_LC" in
  linkedin.com|*.linkedin.com)
    echo "linkedin-notification"
    exit 0
    ;;
esac

# Rule 3: default.
echo "email"
exit 0
