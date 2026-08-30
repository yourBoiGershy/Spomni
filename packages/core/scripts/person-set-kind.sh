#!/usr/bin/env bash
# person-set-kind.sh — the one sanctioned way to write the five `kind*`
# frontmatter fields on a person.md (packages/core/contracts/person.md
# 1.1.0, "Kind vs. tier", plan 30).
#
# Usage:
#   person-set-kind.sh <store-dir> <slug> --kind <kind> --note <text> \
#       --source <derived|stated-by-user> [--expires <YYYY-MM-DD>] \
#       [--today <YYYY-MM-DD>] [--no-index] \
#       [--feedback-text "<words>"] [--feedback-channel <c>] \
#       [--feedback-source reply|session]
#
# Reindex (plan 38 D2): on a successful write, this script calls
# packages/core/scripts/reindex.sh <store-dir> --quiet so index.json and
# stats.json are fresh at return. --no-index skips this — for batch
# callers (e.g. review-tiers' per-person loop) that reindex once themselves
# after the whole batch instead of once per person.
#
# Feedback ledger (plan 34):
#   - --feedback-text / --feedback-channel / --feedback-source are only
#     meaningful with --source stated-by-user; with --source derived they
#     are ignored (a log line notes it, nothing is written).
#   - On a successful stated-by-user write, the script appends one line to
#     the feedback ledger via the ingestion package's feedback-file.sh
#     (found relative to this script). If that script is absent (core
#     tests must never depend on ingestion), the ledger step is skipped
#     with a log line and the script still exits 0. A ledger write failure
#     is logged but never changes this script's exit status.
#
# Rules:
#   - Target people/<slug>.md must already exist (exit 1 otherwise).
#   - Rewrites ONLY the five kind fields (kind, kind_note, kind_source,
#     kind_expires, kind_updated) inside the frontmatter block (between the
#     first two "---" lines): replaces each in place if already present,
#     else inserts them after the `tier:` line (or before the closing
#     "---" if there is no tier line). Every other line is left
#     byte-identical. Write is atomic (temp file + mv).
#   - Provenance asymmetry (person.md 1.1.0): a `--source derived` write
#     never overwrites an existing `kind_source: stated-by-user` — refused
#     with exit 2, file untouched.
#   - `--kind scheduling` requires `--expires` (exit 2 otherwise).
#   - Invalid --kind / --source / date shape -> exit 2. Missing or empty
#     --note -> exit 2.
#   - kind_updated is always set to --today (default: `date +%Y-%m-%d`).
#   - An existing kind_expires is kept unless --expires is given, or the
#     new kind is not `scheduling` (in which case any kind_expires line is
#     removed).
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -u

KIND_VOCAB="friend|family|collaborator|professional|community|scheduling|transactional|unsolicited|unknown"
SOURCE_VOCAB="stated-by-user|derived"

die() {
    printf 'person-set-kind.sh: %s\n' "$1" >&2
    exit "${2:-2}"
}

if [ "$#" -lt 2 ]; then
    die "usage: person-set-kind.sh <store-dir> <slug> --kind <k> --note <text> --source <derived|stated-by-user> [--expires <YYYY-MM-DD>] [--today <YYYY-MM-DD>] [--no-index]" 1
fi

store_dir="$1"; shift
slug="$1"; shift

new_kind=""
new_note=""
new_source=""
new_expires=""
today=""
no_index=0
feedback_text=""
feedback_channel=""
feedback_source="session"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --kind) new_kind="${2:-}"; shift 2 ;;
        --note) new_note="${2:-}"; shift 2 ;;
        --source) new_source="${2:-}"; shift 2 ;;
        --expires) new_expires="${2:-}"; shift 2 ;;
        --today) today="${2:-}"; shift 2 ;;
        --no-index) no_index=1; shift ;;
        --feedback-text) feedback_text="${2:-}"; shift 2 ;;
        --feedback-channel) feedback_channel="${2:-}"; shift 2 ;;
        --feedback-source) feedback_source="${2:-}"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

person_file="${store_dir}/people/${slug}.md"
[ -f "$person_file" ] || die "person file not found: ${person_file}" 1

[ -n "$new_note" ] || die "--note is required and must not be empty"

if ! printf '%s' "$new_kind" | grep -qE "^(${KIND_VOCAB})\$"; then
    die "invalid --kind: '${new_kind}' (expected one of: friend, family, collaborator, professional, community, scheduling, transactional, unsolicited, unknown)"
fi

if ! printf '%s' "$new_source" | grep -qE "^(${SOURCE_VOCAB})\$"; then
    die "invalid --source: '${new_source}' (expected one of: stated-by-user, derived)"
fi

if [ -n "$new_expires" ] && ! printf '%s' "$new_expires" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    die "invalid --expires: '${new_expires}' (expected ISO 8601 date YYYY-MM-DD)"
fi

if [ "$new_kind" = "scheduling" ] && [ -z "$new_expires" ]; then
    die "--kind scheduling requires --expires"
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

# --- refusal: derived write never overwrites a stated kind ---
existing_source_line="$(awk -v s=2 -v e="$fm_end" '
    NR>=s && NR<e && $0 ~ /^kind_source:/ {print; exit}
' "$person_file")"
existing_source_val="$(printf '%s' "$existing_source_line" | sed -E 's/^kind_source:[[:space:]]*//; s/[[:space:]]+$//; s/^"(.*)"$/\1/')"
existing_kind_line="$(awk -v s=2 -v e="$fm_end" '
    NR>=s && NR<e && $0 ~ /^kind:/ {print; exit}
' "$person_file")"
existing_kind_val="$(printf '%s' "$existing_kind_line" | sed -E 's/^kind:[[:space:]]*//; s/[[:space:]]+$//; s/^"(.*)"$/\1/')"

if [ "$new_source" = "derived" ] && [ "$existing_source_val" = "stated-by-user" ]; then
    printf 'refusing: kind is stated-by-user for %s; a derived write never overwrites a stated kind\n' "$slug" >&2
    exit 2
fi

# --- note quoting: wrap in double quotes (escaping embedded ") when the
#     note contains ": " or starts with a YAML-special character. ---
quote_value() {
    local v="$1"
    case "$v" in
        *': '*|'"'*|"'"*|'&'*|'*'*|'!'*|'|'*|'>'*|'%'*|'@'*|'`'*|'#'*|'['*|']'*|'{'*|'}'*|','*|':'*)
            printf '"%s"' "$(printf '%s' "$v" | sed 's/"/\\"/g')"
            ;;
        *)
            printf '%s' "$v"
            ;;
    esac
}

note_out="$(quote_value "$new_note")"

# --- determine kind_expires to write ---
existing_expires_line="$(awk -v s=2 -v e="$fm_end" '
    NR>=s && NR<e && $0 ~ /^kind_expires:/ {print; exit}
' "$person_file")"
existing_expires_val="$(printf '%s' "$existing_expires_line" | sed -E 's/^kind_expires:[[:space:]]*//; s/[[:space:]]+$//; s/^"(.*)"$/\1/')"

expires_out=""
if [ -n "$new_expires" ]; then
    expires_out="$new_expires"
elif [ "$new_kind" = "scheduling" ] && [ -n "$existing_expires_val" ]; then
    expires_out="$existing_expires_val"
fi
# expires_out stays empty (line omitted) for a non-scheduling kind unless
# --expires was explicitly given above.

# Does an existing kind: line already exist in the frontmatter? If so,
# insert the replacement fields at that exact spot (in place). Otherwise
# insert right after tier: (if present), else right before the closing ---.
has_existing_kind_line="$(awk -v s=2 -v e="$fm_end" 'NR>=s && NR<e && $0 ~ /^kind:/ {print "1"; exit}' "$person_file")"
has_tier_line="$(awk -v s=2 -v e="$fm_end" 'NR>=s && NR<e && $0 ~ /^tier:/ {print "1"; exit}' "$person_file")"

if [ -n "$has_existing_kind_line" ]; then
    anchor="kind_line"
elif [ -n "$has_tier_line" ]; then
    anchor="tier_line"
else
    anchor="fm_end"
fi

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

awk -v fm_end="$fm_end" \
    -v kind="$new_kind" \
    -v note="$note_out" \
    -v source="$new_source" \
    -v expires="$expires_out" \
    -v updated="$today" \
    -v has_expires="$([ -n "$expires_out" ] && echo 1 || echo 0)" \
    -v anchor="$anchor" '
    BEGIN { inserted = 0 }
    function emit_kind_fields() {
        print "kind: " kind
        print "kind_note: " note
        print "kind_source: " source
        if (has_expires == 1) {
            print "kind_expires: " expires
        }
        print "kind_updated: " updated
        inserted = 1
    }
    {
        if (NR >= 2 && NR < fm_end && ($0 ~ /^kind:/ || $0 ~ /^kind_note:/ || $0 ~ /^kind_source:/ || $0 ~ /^kind_expires:/ || $0 ~ /^kind_updated:/)) {
            if (anchor == "kind_line" && !inserted) {
                emit_kind_fields()
            }
            next
        }
        print
        if (NR >= 2 && NR < fm_end && anchor == "tier_line" && $0 ~ /^tier:/ && !inserted) {
            emit_kind_fields()
        }
        if (NR == fm_end - 1 && anchor == "fm_end" && !inserted) {
            emit_kind_fields()
        }
    }
' "$person_file" > "$tmp_file"

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
        set -- "$store_dir" --type kind-correction --target "person:${slug}" --source "$feedback_source" --to "$new_kind"
        [ -n "$existing_kind_val" ] && set -- "$@" --from "$existing_kind_val"
        [ -n "$feedback_text" ] && set -- "$@" --text "$feedback_text"
        [ -n "$feedback_channel" ] && set -- "$@" --channel "$feedback_channel"
        "$feedback_script" "$@"
        feedback_rc=$?
        if [ "$feedback_rc" -ne 0 ]; then
            printf 'feedback: ledger write failed (exit %d)\n' "$feedback_rc"
        fi
    fi
fi

printf 'set kind=%s source=%s for %s\n' "$new_kind" "$new_source" "$slug"
exit 0
