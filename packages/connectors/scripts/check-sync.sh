#!/usr/bin/env bash
# check-sync.sh — read-only conformance checker for a store's inbox/ against
# the capture-event contract (packages/core/contracts/capture-event.md,
# schema_version 1.2.0) and the per-lane mapping table in the plan-14 import
# standard.
#
# Usage: check-sync.sh [store-dir]   (defaults to ".")
#
# This audits "are we syncing correctly" for any sweep run (Gmail, Calendar,
# Beeper, live or fixture, plus any legacy-source events already in the
# store) that has landed events in <store-dir>/inbox/. It never writes to
# the store.
#
# Checks per inbox/*.md event (quarantine/ excluded — those are already
# flagged invalid by the writer):
#   1. Frontmatter parses (opening/closing "---") and all required fields
#      are present: schema_version, id, source, captured_at, type.
#   2. schema_version is a known 1.x (1.0.0, 1.1.0, 1.2.0).
#   3. type is in the 1.2.0 enum.
#   4. captured_at matches YYYY-MM-DDTHH:MM:SSZ and is not in the future
#      beyond a 5-minute skew allowance (FAIL — this is the historical
#      calendar-lane defect: event-start time written as captured_at).
#   5. occurred_at, when present, is well-formed ISO 8601.
#   6. filename is flat under inbox/ (no nested path) and equals id.
#   7. no CLI transport wrapper keys ("successful", "logId") appear in the
#      body of a non-quarantine event — guards against any wrapper, not a
#      specific connector.
#   8. lane rules from the per-lane table, only when source declares a
#      lane: gmail-in/*, calendar-in/*, and beeper-in/* events SHOULD have
#      occurred_at (WARN, not FAIL, if missing); other <connector>/<lane>
#      sources (including retired-connector eras) fall through to generic
#      checks only — still valid, never a FAIL just for the source's age;
#      bare legacy sources (e.g. plain "gmail") WARN "pre-standard event,
#      valid 1.0.0".
#   9. no two inbox events share an id; WARN on byte-identical bodies
#      (possible dedup failure).
#
# Output: one line per finding, "FAIL <file>: <reason>" or
# "WARN <file>: <reason>", then a summary line:
#   "SUMMARY: <n> events, <f> failures, <w> warnings"
# Exit 0 only when failures = 0 (warnings do not affect exit status).
# Empty inbox still prints an explicit SUMMARY line — silence is never a
# valid outcome.
#
# validate-store.sh is run first (against people/interactions/wakeups) and
# its result is surfaced before the inbox-specific findings below.
#
# Portable to bash 3.2: no associative arrays, no mapfile.

set -u

store_dir="${1:-.}"
script_dir="$(cd "$(dirname "$0")" && pwd)"

failures=0
warnings=0
events=0

fail() {
    printf 'FAIL %s: %s\n' "$1" "$2"
    failures=$((failures + 1))
}

warn() {
    printf 'WARN %s: %s\n' "$1" "$2"
    warnings=$((warnings + 1))
}

# ---------------------------------------------------------------------------
# Step 0: run validate-store.sh first and surface its result.
# ---------------------------------------------------------------------------

validate_store_script="${script_dir}/../../core/scripts/validate-store.sh"
if [ -x "$validate_store_script" ] || [ -f "$validate_store_script" ]; then
    echo "--- validate-store.sh ---"
    bash "$validate_store_script" "$store_dir"
    vs_exit=$?
    if [ "$vs_exit" -ne 0 ]; then
        echo "validate-store.sh: FAILED (exit ${vs_exit}) — see findings above"
    fi
    echo "--- check-sync.sh (inbox/) ---"
else
    echo "check-sync.sh: validate-store.sh not found at ${validate_store_script}, skipping" >&2
fi

# ---------------------------------------------------------------------------
# Frontmatter helpers (same shape as validate-store.sh).
# ---------------------------------------------------------------------------

find_frontmatter_end() {
    local file="$1"
    local first_line
    first_line=$(head -n1 "$file")
    if [ "$first_line" != "---" ]; then
        return 1
    fi
    local close_line
    close_line=$(awk 'NR>1 && $0=="---"{print NR; exit}' "$file")
    if [ -z "$close_line" ]; then
        return 1
    fi
    printf '%s\n' "$close_line"
    return 0
}

find_field_line() {
    local file="$1" s="$2" e="$3" key="$4"
    awk -v s="$s" -v e="$e" -v k="^${key}:" 'NR>=s && NR<=e && $0 ~ k {print NR; exit}' "$file"
}

scalar_value() {
    local file="$1" line="$2" key="$3"
    sed -n "${line}p" "$file" \
        | sed -E "s/^${key}:[[:space:]]*//" \
        | sed -E 's/[[:space:]]+$//' \
        | sed -E 's/^"(.*)"$/\1/'
}

# ---------------------------------------------------------------------------
# Inbox pass.
# ---------------------------------------------------------------------------

inbox_dir="${store_dir}/inbox"

if [ ! -d "$inbox_dir" ]; then
    echo "SUMMARY: 0 events, 0 failures, 0 warnings (no inbox/ directory)"
    exit 0
fi

ids_file="$(mktemp)"
bodies_dir="$(mktemp -d)"
trap 'rm -rf "$ids_file" "$bodies_dir"' EXIT
: > "$ids_file"

for f in "$inbox_dir"/*.md; do
    [ -e "$f" ] || continue
    # Skip quarantine — it is a directory, not a .md file, so the glob
    # above never enters it; nothing further needed here.

    events=$((events + 1))
    base="$(basename "$f" .md)"

    fm_end=$(find_frontmatter_end "$f")
    if [ -z "$fm_end" ]; then
        fail "$f" "malformed frontmatter: missing opening/closing ---"
        continue
    fi
    fm_start=2
    fm_body_end=$((fm_end - 1))

    # --- required fields ---
    sv_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "schema_version")
    id_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "id")
    source_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "source")
    captured_at_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "captured_at")
    type_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "type")

    [ -n "$sv_line" ] || fail "$f" "missing required field: schema_version"
    [ -n "$id_line" ] || fail "$f" "missing required field: id"
    [ -n "$source_line" ] || fail "$f" "missing required field: source"
    [ -n "$captured_at_line" ] || fail "$f" "missing required field: captured_at"
    [ -n "$type_line" ] || fail "$f" "missing required field: type"

    sv_val=""
    if [ -n "$sv_line" ]; then
        sv_val=$(scalar_value "$f" "$sv_line" "schema_version")
        case "$sv_val" in
            1.0.0|1.1.0|1.2.0) ;;
            *) fail "$f" "unknown schema_version: '${sv_val}' (expected one of: 1.0.0, 1.1.0, 1.2.0)" ;;
        esac
    fi

    id_val=""
    if [ -n "$id_line" ]; then
        id_val=$(scalar_value "$f" "$id_line" "id")
        if [ "$id_val" != "$base" ]; then
            fail "$f" "id '${id_val}' does not match filename stem '${base}'"
        fi
        if printf '%s' "$id_val" | grep -q '/'; then
            fail "$f" "id '${id_val}' is not a flat filename (contains '/')"
        fi
        printf '%s\t%s\n' "$id_val" "$f" >> "$ids_file"
    fi

    source_val=""
    if [ -n "$source_line" ]; then
        source_val=$(scalar_value "$f" "$source_line" "source")
    fi

    if [ -n "$type_line" ]; then
        type_val=$(scalar_value "$f" "$type_line" "type")
        case "$type_val" in
            voice-note|linkedin-notification|event-confirmation|transcript|other|email|calendar-event|profile-snapshot|contact-record|post|chat-message) ;;
            *) fail "$f" "invalid type: '${type_val}' (not in 1.2.0 enum)" ;;
        esac
    fi

    captured_at_val=""
    if [ -n "$captured_at_line" ]; then
        captured_at_val=$(scalar_value "$f" "$captured_at_line" "captured_at")
        if ! printf '%s' "$captured_at_val" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
            fail "$f" "invalid captured_at: '${captured_at_val}' (expected ISO 8601 YYYY-MM-DDTHH:MM:SSZ)"
        else
            # Future-dated captured_at (beyond a 5-minute skew allowance) is
            # the historical calendar-lane defect: event-start time written
            # in place of capture time.
            captured_epoch=""
            if date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$captured_at_val" '+%s' >/dev/null 2>&1; then
                captured_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$captured_at_val" '+%s' 2>/dev/null)
            else
                captured_epoch=$(date -u -d "$captured_at_val" '+%s' 2>/dev/null)
            fi
            now_epoch=$(date -u '+%s')
            if [ -n "$captured_epoch" ]; then
                skew=$((captured_epoch - now_epoch))
                if [ "$skew" -gt 300 ]; then
                    fail "$f" "captured_at '${captured_at_val}' is in the future (skew ${skew}s > 5min allowance)"
                fi
            fi
        fi
    fi

    occurred_at_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "occurred_at")
    if [ -n "$occurred_at_line" ]; then
        occurred_at_val=$(scalar_value "$f" "$occurred_at_line" "occurred_at")
        if ! printf '%s' "$occurred_at_val" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
            fail "$f" "invalid occurred_at: '${occurred_at_val}' (expected ISO 8601 YYYY-MM-DDTHH:MM:SSZ)"
        fi
    fi

    # --- transport wrapper leakage: body must never contain a CLI transport
    # wrapper key ("successful", "logId") from any connector's transport. ---
    body_start=$((fm_end + 1))
    body_tmp="${bodies_dir}/${base}.body"
    tail -n "+${body_start}" "$f" > "$body_tmp"
    if grep -qE '"successful"[[:space:]]*:' "$body_tmp" || grep -qE '"logId"[[:space:]]*:' "$body_tmp"; then
        fail "$f" "body contains a CLI transport wrapper key ('successful' or 'logId') — the transport envelope must never enter the archive"
    fi

    # --- per-lane rules, only when source declares a lane ---
    case "$source_val" in
        gmail-in/*|calendar-in/*|beeper-in/*)
            if [ -z "$occurred_at_line" ]; then
                warn "$f" "source '${source_val}' SHOULD have occurred_at per the per-lane table"
            fi
            ;;
        */*)
            : # other <connector>/<lane> sources (including retired-connector
              # eras): still valid, generic checks only, never a FAIL here
            ;;
        gmail|googlecalendar|linkedin)
            warn "$f" "pre-standard event, valid 1.0.0 (bare legacy source '${source_val}')"
            ;;
        *)
            : # e.g. manual, gmail-in — plain connector names remain valid
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Duplicate id / byte-identical body checks.
# ---------------------------------------------------------------------------

if [ -s "$ids_file" ]; then
    sorted_ids="$(sort -k1,1 "$ids_file")"
    prev_id=""
    prev_file=""
    while IFS=$'\t' read -r id file; do
        [ -n "$id" ] || continue
        if [ "$id" = "$prev_id" ]; then
            fail "$file" "duplicate id '${id}' also used by ${prev_file}"
        fi
        prev_id="$id"
        prev_file="$file"
    done <<EOF
$sorted_ids
EOF
fi

# Byte-identical bodies (possible dedup failure): hash each body, report any
# id sharing a hash with an earlier one.
hashes_file="$(mktemp)"
trap 'rm -rf "$ids_file" "$bodies_dir" "$hashes_file"' EXIT
: > "$hashes_file"
for f in "$inbox_dir"/*.md; do
    [ -e "$f" ] || continue
    base="$(basename "$f" .md)"
    body_tmp="${bodies_dir}/${base}.body"
    [ -e "$body_tmp" ] || continue
    if command -v shasum >/dev/null 2>&1; then
        h=$(shasum -a 256 "$body_tmp" | awk '{print $1}')
    else
        h=$(sha256sum "$body_tmp" | awk '{print $1}')
    fi
    printf '%s\t%s\n' "$h" "$f" >> "$hashes_file"
done

if [ -s "$hashes_file" ]; then
    sorted_hashes="$(sort -k1,1 "$hashes_file")"
    prev_hash=""
    prev_file=""
    while IFS=$'\t' read -r h file; do
        [ -n "$h" ] || continue
        if [ "$h" = "$prev_hash" ]; then
            warn "$file" "byte-identical body to ${prev_file} (possible dedup failure)"
        fi
        prev_hash="$h"
        prev_file="$file"
    done <<EOF
$sorted_hashes
EOF
fi

# ---------------------------------------------------------------------------
# Result.
# ---------------------------------------------------------------------------

echo "SUMMARY: ${events} events, ${failures} failures, ${warnings} warnings"

if [ "$failures" -eq 0 ]; then
    exit 0
else
    exit 1
fi
