#!/usr/bin/env bash
# feedback-file.sh — the sole writer of the append-only feedback ledger
# `<store-dir>/signals/feedback.jsonl` (packages/core/contracts/feedback-event.md
# 1.2.0, plan 34 D1/U8b, plan 36).
#
# Usage:
#   feedback-file.sh <store-dir> --type <enum> --target <target> \
#       --source reply|session|auto [--from <v>] [--to <v>] [--reason <r>] \
#       [--text "<verbatim>"] [--channel <c>] [--ts <ISO8601Z>]
#
# Rules:
#   - `type` must be one of: dismiss, snooze, acted-on, done, opt-out,
#     tier-correction, kind-correction, draft-edit, model-confirm, freeform,
#     draft-request, merge, noise-sender, stale-marked.
#   - `target` must match
#     ^(wakeup:.+|person:[a-z0-9-]+|signal:[a-z0-9-]+|model|sender:.+)$.
#     `sender:<pattern>` is reserved for `--type noise-sender` (1.2.0, plan 36).
#   - `source` must be one of: reply, session, auto.
#   - `--from <slug>` is required when `--type merge` (the dropped slug,
#     bare, no `person:` prefix) — written to the JSON `from` field like any
#     other `--from` value; missing `--from` with `--type merge` exits 2
#     with nothing written.
#   - `--text` is the user's verbatim words — never rewritten, never
#     summarized. It is JSON-escaped as-is (quotes, newlines, unicode all
#     survive intact) via `jq -cn --arg`.
#   - Any missing optional (`--from`, `--to`, `--reason`, `--text`,
#     `--channel`) is written as JSON null.
#   - `--ts` defaults to `date -u +%Y-%m-%dT%H:%M:%SZ` (now, UTC).
#   - Key order in the emitted line: ts, type, target, from, to, reason,
#     text, channel, source.
#   - `mkdir -p <store-dir>/signals`, then a single `>>` append — one line,
#     one write, never rewrites or reorders existing lines.
#   - Any usage or enum-validation failure exits 2 with nothing written.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -u

TYPE_VOCAB="dismiss|snooze|acted-on|done|opt-out|tier-correction|kind-correction|draft-edit|model-confirm|freeform|draft-request|merge|noise-sender|stale-marked"
SOURCE_VOCAB="reply|session|auto"
TARGET_RE="^(wakeup:.+|person:[a-z0-9-]+|signal:[a-z0-9-]+|model|sender:.+)\$"

die() {
    printf 'feedback-file.sh: %s\n' "$1" >&2
    exit "${2:-2}"
}

if [ "$#" -lt 1 ]; then
    die "usage: feedback-file.sh <store-dir> --type <enum> --target <target> --source reply|session|auto [--from <v>] [--to <v>] [--reason <r>] [--text \"<verbatim>\"] [--channel <c>] [--ts <ISO8601Z>]" 2
fi

store_dir="$1"; shift

type=""
target=""
source=""
from=""
to=""
reason=""
text=""
channel=""
ts=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --type) type="${2:-}"; shift 2 ;;
        --target) target="${2:-}"; shift 2 ;;
        --source) source="${2:-}"; shift 2 ;;
        --from) from="${2:-}"; shift 2 ;;
        --to) to="${2:-}"; shift 2 ;;
        --reason) reason="${2:-}"; shift 2 ;;
        --text) text="${2:-}"; shift 2 ;;
        --channel) channel="${2:-}"; shift 2 ;;
        --ts) ts="${2:-}"; shift 2 ;;
        *) die "unknown argument: $1" 2 ;;
    esac
done

[ -n "$store_dir" ] || die "missing <store-dir>" 2

if ! printf '%s' "$type" | grep -qE "^(${TYPE_VOCAB})\$"; then
    die "invalid --type: '${type}' (expected one of: dismiss, snooze, acted-on, done, opt-out, tier-correction, kind-correction, draft-edit, model-confirm, freeform, draft-request, merge, noise-sender, stale-marked)" 2
fi

if ! printf '%s' "$target" | grep -qE "$TARGET_RE"; then
    die "invalid --target: '${target}' (expected wakeup:<id>, person:<slug>, signal:<type>, model, or sender:<pattern>)" 2
fi

if ! printf '%s' "$source" | grep -qE "^(${SOURCE_VOCAB})\$"; then
    die "invalid --source: '${source}' (expected one of: reply, session, auto)" 2
fi

if [ "$type" = "merge" ] && [ -z "$from" ]; then
    die "--type merge requires --from <dropped-slug>" 2
fi

if [ -z "$ts" ]; then
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

command -v jq >/dev/null 2>&1 || die "jq is required" 2

mkdir -p "${store_dir}/signals" || die "could not create ${store_dir}/signals" 2

line="$(jq -cn \
    --arg ts "$ts" \
    --arg type "$type" \
    --arg target "$target" \
    --arg from "$from" \
    --arg to "$to" \
    --arg reason "$reason" \
    --arg text "$text" \
    --arg channel "$channel" \
    --arg source "$source" \
    --argjson has_from "$([ -n "$from" ] && echo true || echo false)" \
    --argjson has_to "$([ -n "$to" ] && echo true || echo false)" \
    --argjson has_reason "$([ -n "$reason" ] && echo true || echo false)" \
    --argjson has_text "$([ -n "$text" ] && echo true || echo false)" \
    --argjson has_channel "$([ -n "$channel" ] && echo true || echo false)" \
    '{
        ts: $ts,
        type: $type,
        target: $target,
        from: ($has_from | if . then $from else null end),
        to: ($has_to | if . then $to else null end),
        reason: ($has_reason | if . then $reason else null end),
        text: ($has_text | if . then $text else null end),
        channel: ($has_channel | if . then $channel else null end),
        source: $source
    }'
)" || die "jq failed to build the ledger line" 2

printf '%s\n' "$line" >> "${store_dir}/signals/feedback.jsonl" || die "could not append to ${store_dir}/signals/feedback.jsonl" 2

printf 'feedback: %s %s\n' "$type" "$target"
exit 0
