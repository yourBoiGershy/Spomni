#!/usr/bin/env bash
# person-set-tier.sh — the one sanctioned way to write the `tier` /
# `tier_source` frontmatter fields on a person.md
# (packages/core/contracts/person.md 1.2.0, "Kind vs. tier", plan 31 D4).
#
# Usage:
#   person-set-tier.sh <store-dir> <slug> --tier <t> --source <derived|stated-by-user> \
#       [--today <YYYY-MM-DD>] [--no-index] \
#       [--feedback-text "<words>"] [--feedback-channel <c>] \
#       [--feedback-source reply|session]
#   person-set-tier.sh <store-dir> <slug> --clear --source stated-by-user \
#       [--today <YYYY-MM-DD>] [--no-index] \
#       [--feedback-text "<words>"] [--feedback-channel <c>] \
#       [--feedback-source reply|session]
#
# Reindex (plan 38 D2): on a successful write (set or --clear), this script
# calls packages/core/scripts/reindex.sh <store-dir> --quiet so index.json
# and stats.json are fresh at return. --no-index skips this — for batch
# callers (e.g. review-tiers' per-person loop) that reindex once themselves
# after the whole batch instead of once per person.
#
# Feedback ledger (plan 34):
#   - --feedback-text / --feedback-channel / --feedback-source are only
#     meaningful with --source stated-by-user; with --source derived they
#     are ignored (a log line notes it, nothing is written).
#   - On a successful stated-by-user write (including --clear), the script
#     appends one line to the feedback ledger via the ingestion package's
#     feedback-file.sh (found relative to this script). If that script is
#     absent (core tests must never depend on ingestion), the ledger step
#     is skipped with a log line and the script still exits 0. A ledger
#     write failure is logged but never changes this script's exit status.
#
# Rules:
#   - Target people/<slug>.md must already exist (exit 1 otherwise).
#   - Rewrites ONLY the two tier fields (tier, tier_source) inside the
#     frontmatter block (between the first two "---" lines): replaces each
#     in place if already present, else inserts tier_source right after
#     tier (or tier itself, then tier_source, after last-touch if neither
#     is present, else before the closing "---"). Every other line is left
#     byte-identical. Write is atomic (temp file + mv).
#   - Provenance asymmetry (person.md 1.2.0): a `--source derived` write
#     never overwrites an existing `tier_source: stated-by-user` — refused
#     with exit 2, file untouched. A missing tier_source on an existing
#     tier line reads as stated-by-user (legacy default) for this check.
#   - Invalid --tier / --source / date shape -> exit 2.
#   - `--clear` removes both the tier and tier_source lines — only allowed
#     when --source stated-by-user (a user correction saying "no tier");
#     `--clear --source derived` -> exit 2. `--clear` is refused (exit 2)
#     against an existing `tier_source: stated-by-user` unless --source
#     stated-by-user is also given (which it must be per the rule above,
#     so this is always consistent).
#   - tier_source is always set to --source on a non-clear write.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -u

TIER_VOCAB="inner-circle|close|active|dormant"
SOURCE_VOCAB="stated-by-user|derived"

die() {
    printf 'person-set-tier.sh: %s\n' "$1" >&2
    exit "${2:-2}"
}

if [ "$#" -lt 2 ]; then
    die "usage: person-set-tier.sh <store-dir> <slug> --tier <t> --source <derived|stated-by-user> [--today <YYYY-MM-DD>] [--no-index] | --clear --source stated-by-user" 1
fi

store_dir="$1"; shift
slug="$1"; shift

new_tier=""
new_source=""
today=""
do_clear=0
no_index=0
feedback_text=""
feedback_channel=""
feedback_source="session"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tier) new_tier="${2:-}"; shift 2 ;;
        --source) new_source="${2:-}"; shift 2 ;;
        --today) today="${2:-}"; shift 2 ;;
        --clear) do_clear=1; shift ;;
        --no-index) no_index=1; shift ;;
        --feedback-text) feedback_text="${2:-}"; shift 2 ;;
        --feedback-channel) feedback_channel="${2:-}"; shift 2 ;;
        --feedback-source) feedback_source="${2:-}"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

person_file="${store_dir}/people/${slug}.md"
[ -f "$person_file" ] || die "person file not found: ${person_file}" 1

if ! printf '%s' "$new_source" | grep -qE "^(${SOURCE_VOCAB})\$"; then
    die "invalid --source: '${new_source}' (expected one of: stated-by-user, derived)"
fi

if [ "$do_clear" -eq 1 ] && [ -n "$new_tier" ]; then
    die "--clear and --tier are mutually exclusive"
fi

if [ "$do_clear" -eq 0 ] && ! printf '%s' "$new_tier" | grep -qE "^(${TIER_VOCAB})\$"; then
    die "invalid --tier: '${new_tier}' (expected one of: inner-circle, close, active, dormant)"
fi

if [ "$do_clear" -eq 1 ] && [ "$new_source" != "stated-by-user" ]; then
    die "--clear requires --source stated-by-user (a derived write may never clear a tier)"
fi

if [ -z "$today" ]; then
    today="$(date +%Y-%m-%d)"
fi
if ! printf '%s' "$today" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    die "invalid --today: '${today}' (expected ISO 8601 date YYYY-MM-DD)"
fi

# --- locate frontmatter block ---
first_line="$(head -n1 "$person_file")"
[ "$first_line" = "---" ] || die "malformed frontmatter in ${person_file}: missing opening ---" 1
fm_end="$(awk 'NR>1 && $0=="---"{print NR; exit}' "$person_file")"
[ -n "$fm_end" ] || die "malformed frontmatter in ${person_file}: missing closing ---" 1

# --- refusal: derived write never overwrites a stated tier (or clears it) ---
existing_tier_line="$(awk -v s=2 -v e="$fm_end" '
    NR>=s && NR<e && $0 ~ /^tier:/ {print; exit}
' "$person_file")"
existing_source_line="$(awk -v s=2 -v e="$fm_end" '
    NR>=s && NR<e && $0 ~ /^tier_source:/ {print; exit}
' "$person_file")"
existing_source_val="$(printf '%s' "$existing_source_line" | sed -E 's/^tier_source:[[:space:]]*//; s/[[:space:]]+$//; s/^"(.*)"$/\1/')"
existing_tier_val="$(printf '%s' "$existing_tier_line" | sed -E 's/^tier:[[:space:]]*//; s/[[:space:]]+$//; s/^"(.*)"$/\1/')"

# Legacy default: a tier with no tier_source reads as stated-by-user.
if [ -n "$existing_tier_line" ] && [ -z "$existing_source_val" ]; then
    existing_source_val="stated-by-user"
fi

if [ "$new_source" = "derived" ] && [ "$existing_source_val" = "stated-by-user" ]; then
    printf 'refusing: tier is stated-by-user for %s; a derived write never overwrites a stated tier\n' "$slug" >&2
    exit 2
fi

# Does an existing tier: line already exist in the frontmatter? If so,
# insert the replacement fields at that exact spot (in place). Otherwise
# insert right after last-touch: (if present), else right before the
# closing "---".
has_existing_tier_line="$(awk -v s=2 -v e="$fm_end" 'NR>=s && NR<e && $0 ~ /^tier:/ {print "1"; exit}' "$person_file")"
has_last_touch_line="$(awk -v s=2 -v e="$fm_end" 'NR>=s && NR<e && $0 ~ /^last-touch:/ {print "1"; exit}' "$person_file")"

if [ -n "$has_existing_tier_line" ]; then
    anchor="tier_line"
elif [ -n "$has_last_touch_line" ]; then
    anchor="last_touch_line"
else
    anchor="fm_end"
fi

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

if [ "$do_clear" -eq 1 ]; then
    # --- clear: remove tier + tier_source lines, touch nothing else ---
    awk -v fm_end="$fm_end" '
        {
            if (NR >= 2 && NR < fm_end && ($0 ~ /^tier:/ || $0 ~ /^tier_source:/)) {
                next
            }
            print
        }
    ' "$person_file" > "$tmp_file"
else
    awk -v fm_end="$fm_end" \
        -v tier="$new_tier" \
        -v source="$new_source" \
        -v anchor="$anchor" '
        BEGIN { inserted = 0 }
        function emit_tier_fields() {
            print "tier: " tier
            print "tier_source: " source
            inserted = 1
        }
        {
            if (NR >= 2 && NR < fm_end && ($0 ~ /^tier:/ || $0 ~ /^tier_source:/)) {
                if (anchor == "tier_line" && !inserted) {
                    emit_tier_fields()
                }
                next
            }
            print
            if (NR >= 2 && NR < fm_end && anchor == "last_touch_line" && $0 ~ /^last-touch:/ && !inserted) {
                emit_tier_fields()
            }
            if (NR == fm_end - 1 && anchor == "fm_end" && !inserted) {
                emit_tier_fields()
            }
        }
    ' "$person_file" > "$tmp_file"
fi

mv "$tmp_file" "$person_file"
trap - EXIT

# --- reindex (plan 38 D2): keep index.json/stats.json fresh at return ---
if [ "$no_index" -ne 1 ]; then
    bash "$(dirname "$0")/reindex.sh" "$store_dir" --quiet
fi

# --- feedback ledger (plan 34): only a stated-by-user write earns an entry ---
if [ "$new_source" != "stated-by-user" ]; then
    if [ -n "$feedback_text" ] || [ -n "$feedback_channel" ]; then
        printf 'feedback: ignoring --feedback-* (source is not stated-by-user)\n'
    fi
else
    feedback_script="$(dirname "$0")/../../ingestion/scripts/feedback-file.sh"
    if [ ! -f "$feedback_script" ]; then
        printf 'feedback: skipped (feedback-file.sh absent)\n'
    else
        to_val="$new_tier"
        [ "$do_clear" -eq 1 ] && to_val="null"
        set -- "$store_dir" --type tier-correction --target "person:${slug}" --source "$feedback_source" --to "$to_val"
        [ -n "$existing_tier_val" ] && set -- "$@" --from "$existing_tier_val"
        [ -n "$feedback_text" ] && set -- "$@" --text "$feedback_text"
        [ -n "$feedback_channel" ] && set -- "$@" --channel "$feedback_channel"
        "$feedback_script" "$@"
        feedback_rc=$?
        if [ "$feedback_rc" -ne 0 ]; then
            printf 'feedback: ledger write failed (exit %d)\n' "$feedback_rc"
        fi
    fi
fi

if [ "$do_clear" -eq 1 ]; then
    printf 'cleared tier for %s\n' "$slug"
else
    printf 'set tier=%s source=%s for %s\n' "$new_tier" "$new_source" "$slug"
fi
exit 0
