#!/usr/bin/env bash
# feedback-recent.sh — renders the `## Recent corrections` (and, on request,
# `## Recent draft edits`) block every judgment prompt includes, read-only
# over `<store-dir>/signals/feedback.jsonl` (packages/core/contracts/
# feedback-event.md 1.0.0, packages/ingestion/specs/feedback-ledger.md,
# plan 34).
#
# Usage:
#   feedback-recent.sh <store-dir> [--n 10] [--kind corrections|draft-edits|all]
#                       [--person <slug>]
#
# Rules:
#   - Reads `<store-dir>/signals/feedback.jsonl` only; never writes.
#   - `corrections` = type tier-correction | kind-correction (default kind).
#   - `draft-edits` = type draft-edit, rendered under its own heading.
#   - `all` renders both blocks, corrections first.
#   - date shown = `ts`'s first 10 chars (YYYY-MM-DD).
#   - correction line: judge said <field>=<from|(none)>, user said
#     <field>=<to>[, words: "<text>"] — the words segment is omitted
#     entirely when `text` is null. <field> is `kind` or `tier` per type.
#   - draft-edit line: `- <date> <target> — <text>`.
#   - newest first (by `ts`), ties broken by file order; `--n` caps the
#     count (default 10).
#   - `--person <slug>` filters to `target == person:<slug>`.
#   - missing file, empty ledger, or no matches for a block -> that block's
#     heading followed by `_none yet_`. Always exits 0.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -u

die() {
    printf 'feedback-recent.sh: %s\n' "$1" >&2
    exit "${2:-2}"
}

if [ "$#" -lt 1 ]; then
    die "usage: feedback-recent.sh <store-dir> [--n 10] [--kind corrections|draft-edits|all] [--person <slug>]" 2
fi

store_dir="$1"; shift

n=10
kind="corrections"
person=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --n) n="${2:-10}"; shift 2 ;;
        --kind) kind="${2:-}"; shift 2 ;;
        --person) person="${2:-}"; shift 2 ;;
        *) die "unknown argument: $1" 2 ;;
    esac
done

case "$kind" in
    corrections|draft-edits|all) ;;
    *) die "invalid --kind: '${kind}' (expected corrections, draft-edits, or all)" 2 ;;
esac

command -v jq >/dev/null 2>&1 || die "jq is required" 2

feedback_file="${store_dir}/signals/feedback.jsonl"

render_block() {
    # $1 = heading, $2 = jq type-select expr, $3 = jq line-format expr
    heading="$1"
    type_select="$2"
    line_fmt="$3"

    printf '%s\n' "$heading"

    body=""
    if [ -f "$feedback_file" ]; then
        body="$(jq -rs \
            --argjson n "$n" \
            --arg person "$person" \
            "
            [to_entries[] | select(.value | ${type_select})]
            | (if \$person != \"\" then map(select(.value.target == (\"person:\" + \$person))) else . end)
            | sort_by(.value.ts) | reverse
            | .[0:\$n]
            | map(.value | ${line_fmt})
            | .[]
            " "$feedback_file" 2>/dev/null)"
    fi

    if [ -n "$body" ]; then
        printf '%s\n' "$body"
    else
        printf '_none yet_\n'
    fi
}

correction_type_select='(.type == "tier-correction" or .type == "kind-correction")'
correction_line_fmt='(
    (if .type == "tier-correction" then "tier" else "kind" end) as $field
    | (if .from == null then "(none)" else .from end) as $from
    | (if .text == null then "" else ", words: \"" + .text + "\"" end) as $words
    | "- " + (.ts[0:10]) + " " + .target + " — judge said " + $field + "=" + $from
      + ", user said " + $field + "=" + .to + $words
)'

draft_type_select='(.type == "draft-edit")'
draft_line_fmt='"- " + (.ts[0:10]) + " " + .target + " — " + (.text // "")'

case "$kind" in
    corrections)
        render_block "## Recent corrections" "$correction_type_select" "$correction_line_fmt"
        ;;
    draft-edits)
        render_block "## Recent draft edits" "$draft_type_select" "$draft_line_fmt"
        ;;
    all)
        render_block "## Recent corrections" "$correction_type_select" "$correction_line_fmt"
        printf '\n'
        render_block "## Recent draft edits" "$draft_type_select" "$draft_line_fmt"
        ;;
esac

exit 0
