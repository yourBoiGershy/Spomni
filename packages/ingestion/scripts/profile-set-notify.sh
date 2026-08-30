#!/usr/bin/env bash
# profile-set-notify.sh — the one sanctioned way to write the `## Notify`
# section of profile.md (packages/core/contracts/profile.md 1.1.0, plan 33).
#
# Usage:
#   profile-set-notify.sh <store-dir> \
#       [--channel beeper-self|gmail-self|outbox|none] \
#       [--beeper-chat-id <id>] \
#       [--gmail-address <addr>] \
#       [--quiet-hours HH:MM-HH:MM] \
#       [--today YYYY-MM-DD]
#
# Rules:
#   - If <store-dir>/profile.md is absent, it is created from
#     packages/core/templates/profile.md first.
#   - Ensures a `## Notify` section exists (appended after `## Style notes`
#     if missing).
#   - For each given option, adds or replaces the matching bullet with:
#       - **[stated-by-user]** <key>: <value> (<today>)
#     where key is one of channel|beeper_chat_id|gmail_address|quiet_hours.
#     Replacing a bullet leaves every other bullet and every other section
#     byte-identical.
#   - --channel must be one of the enum; --quiet-hours must match
#     HH:MM-HH:MM (each half [0-2][0-9]:[0-5][0-9]); invalid input exits 2
#     with nothing written. No options given at all is also a usage error
#     (exit 2).
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -u

CHANNEL_VOCAB="beeper-self|gmail-self|outbox|none"

die() {
    printf 'profile-set-notify.sh: %s\n' "$1" >&2
    exit "${2:-2}"
}

if [ "$#" -lt 1 ]; then
    die "usage: profile-set-notify.sh <store-dir> [--channel <c>] [--beeper-chat-id <id>] [--gmail-address <addr>] [--quiet-hours HH:MM-HH:MM] [--today YYYY-MM-DD]" 2
fi

store_dir="$1"; shift

new_channel=""
new_beeper_chat_id=""
new_gmail_address=""
new_quiet_hours=""
today=""
have_channel=0
have_beeper_chat_id=0
have_gmail_address=0
have_quiet_hours=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --channel) new_channel="${2:-}"; have_channel=1; shift 2 ;;
        --beeper-chat-id) new_beeper_chat_id="${2:-}"; have_beeper_chat_id=1; shift 2 ;;
        --gmail-address) new_gmail_address="${2:-}"; have_gmail_address=1; shift 2 ;;
        --quiet-hours) new_quiet_hours="${2:-}"; have_quiet_hours=1; shift 2 ;;
        --today) today="${2:-}"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

if [ "$have_channel" -eq 0 ] && [ "$have_beeper_chat_id" -eq 0 ] \
   && [ "$have_gmail_address" -eq 0 ] && [ "$have_quiet_hours" -eq 0 ]; then
    die "usage: at least one of --channel/--beeper-chat-id/--gmail-address/--quiet-hours is required" 2
fi

if [ "$have_channel" -eq 1 ] && ! printf '%s' "$new_channel" | grep -qE "^(${CHANNEL_VOCAB})\$"; then
    die "invalid --channel: '${new_channel}' (expected one of: beeper-self, gmail-self, outbox, none)"
fi

if [ "$have_quiet_hours" -eq 1 ] && ! printf '%s' "$new_quiet_hours" | grep -qE '^[0-2][0-9]:[0-5][0-9]-[0-2][0-9]:[0-5][0-9]$'; then
    die "invalid --quiet-hours: '${new_quiet_hours}' (expected HH:MM-HH:MM)"
fi

if [ -z "$today" ]; then
    today="$(date +%Y-%m-%d)"
fi
if ! printf '%s' "$today" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    die "invalid --today: '${today}' (expected ISO 8601 date YYYY-MM-DD)"
fi

profile_file="${store_dir}/profile.md"

if [ ! -f "$profile_file" ]; then
    template="$(cd "$(dirname "$0")/../../.." && pwd)/packages/core/templates/profile.md"
    [ -f "$template" ] || die "profile template not found: ${template}" 1
    mkdir -p "$store_dir"
    cp "$template" "$profile_file"
fi

# --- bump schema_version 1.0.0 -> 1.1.0 if needed ---
if grep -qE '^schema_version:[[:space:]]*1\.0\.0[[:space:]]*$' "$profile_file"; then
    tmp_fm="$(mktemp)"
    sed -E 's/^schema_version:[[:space:]]*1\.0\.0[[:space:]]*$/schema_version: 1.1.0/' "$profile_file" > "$tmp_fm"
    mv "$tmp_fm" "$profile_file"
fi

# --- ensure `## Notify` section exists ---
# Per the profile contract, `## Notify` is always the last section when
# present (Priorities, Cadence wishes, Signal opt-outs, Style notes, then
# optional Notify) — so a missing section is always appended at EOF.
if ! grep -qE '^## Notify$' "$profile_file"; then
    # Strip trailing blank lines first so we get exactly one blank-line
    # separator before the new section header.
    tmp_trim="$(mktemp)"
    awk '{ lines[NR] = $0 } END {
        last = NR
        while (last > 0 && lines[last] == "") last--
        for (i = 1; i <= last; i++) print lines[i]
    }' "$profile_file" > "$tmp_trim"
    mv "$tmp_trim" "$profile_file"
    printf '\n## Notify\n' >> "$profile_file"
fi

# --- locate `## Notify` section bounds ---
notify_start="$(awk '/^## Notify$/{print NR; exit}' "$profile_file")"
[ -n "$notify_start" ] || die "internal error: ## Notify section missing after ensure step" 1

next_section="$(awk -v s="$notify_start" 'NR>s && /^## /{print NR; exit}' "$profile_file")"
if [ -z "$next_section" ]; then
    # Notify is the last section: bound is one past EOF.
    total_lines="$(wc -l < "$profile_file" | tr -d ' ')"
    notify_end="$((total_lines + 1))"
else
    notify_end="$next_section"
fi

apply_field() {
    field_key="$1"
    field_value="$2"
    bullet_line="- **[stated-by-user]** ${field_key}: ${field_value} (${today})"

    tmp_file="$(mktemp)"
    awk -v s="$notify_start" -v e="$notify_end" -v key="$field_key" -v bullet="$bullet_line" '
        BEGIN { inserted = 0; pattern = "^- \\*\\*\\[stated-by-user\\]\\*\\* " key ":" }
        {
            if (NR > s && NR < e && $0 ~ pattern) {
                if (!inserted) {
                    print bullet
                    inserted = 1
                }
                next
            }
            print
            if (NR == e - 1 && !inserted) {
                print bullet
                inserted = 1
            }
        }
    ' "$profile_file" > "$tmp_file"
    mv "$tmp_file" "$profile_file"

    # Recompute notify_end since we may have inserted a line.
    next_section="$(awk -v s="$notify_start" 'NR>s && /^## /{print NR; exit}' "$profile_file")"
    if [ -z "$next_section" ]; then
        total_lines="$(wc -l < "$profile_file" | tr -d ' ')"
        notify_end="$((total_lines + 1))"
    else
        notify_end="$next_section"
    fi
}

[ "$have_channel" -eq 1 ] && apply_field "channel" "$new_channel"
[ "$have_beeper_chat_id" -eq 1 ] && apply_field "beeper_chat_id" "$new_beeper_chat_id"
[ "$have_gmail_address" -eq 1 ] && apply_field "gmail_address" "$new_gmail_address"
[ "$have_quiet_hours" -eq 1 ] && apply_field "quiet_hours" "$new_quiet_hours"

# --- reflect resulting section state in the summary line ---
notify_start="$(awk '/^## Notify$/{print NR; exit}' "$profile_file")"
next_section="$(awk -v s="$notify_start" 'NR>s && /^## /{print NR; exit}' "$profile_file")"
if [ -z "$next_section" ]; then
    total_lines="$(wc -l < "$profile_file" | tr -d ' ')"
    notify_end="$((total_lines + 1))"
else
    notify_end="$next_section"
fi

read_field() {
    key="$1"
    awk -v s="$notify_start" -v e="$notify_end" -v key="$key" '
        BEGIN { pattern = "^- \\*\\*\\[stated-by-user\\]\\*\\* " key ": " }
        NR > s && NR < e && $0 ~ pattern {
            line = $0
            sub(pattern, "", line)
            sub(/ \([0-9-]+\)$/, "", line)
            print line
            exit
        }
    ' "$profile_file"
}

out_channel="$(read_field "channel")"
out_beeper_chat_id="$(read_field "beeper_chat_id")"
out_gmail_address="$(read_field "gmail_address")"
out_quiet_hours="$(read_field "quiet_hours")"

printf 'notify: channel=%s beeper_chat_id=%s gmail_address=%s quiet_hours=%s\n' \
    "${out_channel:--}" "${out_beeper_chat_id:--}" "${out_gmail_address:--}" "${out_quiet_hours:--}"

exit 0
