#!/bin/bash
# render-nudge-cards.sh — turns one fired wake-up batch into a single
# plain-text chat message: numbered cards the human can reply to
# (packages/core/contracts/nudge-card.md 1.0.0).
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
# Output: one plain-text message on stdout. Numbered cards in `entries[]`
# order, then any `mentions[]` lines, then the fixed reply-grammar footer.
# See the contract for the exact per-card/footer text.
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

entries_json="$(jq -c '.entries[]' "${batch_file}")"

blocks=()
i=0
while IFS= read -r entry; do
    [ -n "${entry}" ] || continue
    i=$((i + 1))

    why="$(printf '%s' "${entry}" | jq -r '.why // empty')"
    signal_type="$(printf '%s' "${entry}" | jq -r '.signal_type // empty')"
    people="$(printf '%s' "${entry}" | jq -r '(.people // []) | map(sub("^\\[\\["; "") | sub("\\]\\]$"; "") | "[[" + . + "]]") | join(", ")')"
    context="$(printf '%s' "${entry}" | jq -r '.context // empty')"
    draft="$(printf '%s' "${entry}" | jq -r '.draft // empty')"
    kind="$(printf '%s' "${entry}" | jq -r '.kind // "nudge"')"
    proposed_title="$(printf '%s' "${entry}" | jq -r '.proposed_event.title // empty')"
    proposed_start="$(printf '%s' "${entry}" | jq -r '.proposed_event.start // empty')"
    proposed_end="$(printf '%s' "${entry}" | jq -r '.proposed_event.end // empty')"

    if [ -n "${signal_type}" ]; then
        header="${i}. ${why} (${signal_type})"
    else
        header="${i}. ${why}"
    fi

    card="${header}"$'\n'"${people}"
    if [ -n "${context}" ]; then
        card="${card}"$'\n'"${context}"
    fi
    if [ -n "${draft}" ]; then
        card="${card}"$'\n'"Draft (unsent):"$'\n'"${draft}"
    fi
    if [ "${kind}" = "event-proposal" ]; then
        card="${card}"$'\n'"Proposed: ${proposed_title} — ${proposed_start} → ${proposed_end}"
        card="${card}"$'\n'"Reply \"${i} done\" after you create it."
    fi

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

footer='Reply with the number: <n> done | <n> snooze <dur> | <n> skip | <n> never <signal-type> | <n> not-them | <n> wrong-tier <tier>'

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
