#!/bin/bash
# render-nudge-cards.sh — turns one fired wake-up batch into a single
# plain-text chat message: numbered cards the human can reply to
# (packages/core/contracts/nudge-card.md 1.1.0).
#
# Usage:
#   render-nudge-cards.sh <batch.json> [--today <YYYY-MM-DD>]
#
# <batch.json> is the artifact written by
# packages/attention/scripts/wakeup-queue.sh fire
# (wakeups/fired/<today>T<HHMMSS>Z-batch.json). --today is accepted for
# forward compatibility but is not consulted by any render rule — the
# no-guilt list (contract's "never rendered") includes batch age, so this
# renderer never compares --today against anything in the batch.
#
# Output: one plain-text message on stdout. Numbered cards (max 5, first 5
# entries[] only — cards beyond the 5th are silently not rendered), then
# any `mentions[]` lines, then the fixed reply-grammar footer. Each card is
# exactly two lines: "<n>. <people> — <why>" and a deterministic "→ <action>"
# line derived from proposed_event/signal_type/origin — never the free-text
# draft. context/draft are never rendered here; the draft is served only on
# a "<n> draft" reply (plan 34 U8b). See the contract for the exact text.
#
# Exit codes:
#   0 — rendered normally
#   2 — input file missing, unreadable, or not valid JSON (stderr line)
#   3 — entries is empty/absent — no output, nothing to say
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -u

SCRIPT_NAME="render-nudge-cards.sh"

die() {
    printf '%s: %s\n' "${SCRIPT_NAME}" "$1" >&2
    exit "${2:-2}"
}

[ "$#" -ge 1 ] || die "usage: render-nudge-cards.sh <batch.json> [--today <YYYY-MM-DD>]" 2

batch_file="$1"; shift

today=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --today) today="${2:-}"; shift 2 ;;
        *) die "unknown argument: $1" 2 ;;
    esac
done
: "${today}" # accepted, intentionally unused (see header comment)

[ -f "${batch_file}" ] || die "batch file not found: ${batch_file}" 2
jq empty "${batch_file}" >/dev/null 2>&1 || die "not valid JSON: ${batch_file}" 2

entry_count="$(jq '(.entries // []) | length' "${batch_file}")"
[ "${entry_count}" -gt 0 ] 2>/dev/null || exit 3

entries_json="$(jq -c '.entries[:5][]' "${batch_file}")"

blocks=()
i=0
while IFS= read -r entry; do
    [ -n "${entry}" ] || continue
    i=$((i + 1))

    why="$(printf '%s' "${entry}" | jq -r '.why // empty')"
    signal_type="$(printf '%s' "${entry}" | jq -r '.signal_type // empty')"
    origin="$(printf '%s' "${entry}" | jq -r '.origin // empty')"
    people="$(printf '%s' "${entry}" | jq -r '(.people // []) | map(sub("^\\[\\["; "") | sub("\\]\\]$"; "") | "[[" + . + "]]") | join(", ")')"
    proposed_title="$(printf '%s' "${entry}" | jq -r '.proposed_event.title // empty')"
    proposed_start="$(printf '%s' "${entry}" | jq -r '.proposed_event.start // empty')"
    has_proposed="$(printf '%s' "${entry}" | jq -r 'if .proposed_event then "1" else "0" end')"

    if [ -n "${signal_type}" ]; then
        header="${i}. ${people} — ${why} (${signal_type})"
    else
        header="${i}. ${people} — ${why}"
    fi

    if [ "${has_proposed}" = "1" ]; then
        action="→ create \"${proposed_title}\" ${proposed_start} and reply \"${i} done\""
    else
        case "${signal_type}" in
            birthday) action="→ send a birthday note today" ;;
            job-change) action="→ congratulate them on the new role" ;;
            scheduling-intent) action="→ propose a time this week" ;;
            co-attendance) action="→ follow up on what you discussed" ;;
            company-news) action="→ send a note about the news" ;;
            tier-drift) action="→ reach out this week — it's been a while" ;;
            linkedin-post) action="→ react to their post with a line" ;;
            *)
                if [ "${origin}" = "user-ask" ]; then
                    action="→ do what you asked yourself to do"
                else
                    action="→ reach out this week"
                fi
                ;;
        esac
    fi

    card="${header}"$'\n'"${action}"
    blocks+=("${card}")
done <<EOF
${entries_json}
EOF

mention_count="$(jq '(.mentions // []) | length' "${batch_file}")"
if [ "${mention_count}" -gt 0 ] 2>/dev/null; then
    mention_lines="$(jq -r '.mentions[].line' "${batch_file}")"
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        blocks+=("${line}")
    done <<EOF
${mention_lines}
EOF
fi

footer='Reply: <n> draft | <n> done | <n> snooze <dur> | <n> skip | <n> never <signal-type> | <n> not-them | <n> wrong-tier <tier>'

message=""
for b in "${blocks[@]}"; do
    if [ -z "${message}" ]; then
        message="${b}"
    else
        message="${message}"$'\n\n'"${b}"
    fi
done
message="${message}"$'\n\n'"${footer}"

printf '%s\n' "${message}"
exit 0
