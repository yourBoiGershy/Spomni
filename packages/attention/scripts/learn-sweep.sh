#!/usr/bin/env bash
# learn-sweep.sh — plan 36 D (narrowed), plan 34 D4: a deterministic,
# no-model sync-tick that pays the cost of re-explaining exactly once.
# It walks a cursor over the append-only feedback ledger, turns the new
# corrections into learned regression eval cases (via ingestion's
# feedback-to-evals.sh), detects corrections that disagree with each other
# and holds them for the user instead of silently picking one ("latest
# wins" would be an auto-resolution — plan 36 D forbids that), and prints a
# 3-line digest. Scheduled as the `learn` sync lane.
#
# INVARIANT: this script never writes user-model.md, people/,
# ranking-weights.json, or signals/feedback.jsonl (user-model rules/
# proposals are plan 34 U31/U32, out of scope here). The only things it
# writes are:
#   <data-dir>/attention/learn-sweep.cursor      (this script, sole writer)
#   <data-dir>/attention/learn-conflicts.tsv     (this script, sole writer)
#   <data-dir>/evals/feedback/**                 (via ingestion's
#                                                  feedback-to-evals.sh —
#                                                  sanctioned cross-package
#                                                  call, plan 34 D1
#                                                  precedent)
#
# Usage:
#   learn-sweep.sh <store-dir> --data-dir <data-dir> [--dry-run]
#
# Paths:
#   ledger (read-only):  <store-dir>/signals/feedback.jsonl
#                         (feedback-event@1.1.0, JSONL, append-only, never
#                         rewritten — see packages/core/contracts/
#                         feedback-event.md). Corrections are lines with
#                         type in {tier-correction, kind-correction} and
#                         target starting "person:".
#   cursor:               <data-dir>/attention/learn-sweep.cursor — a
#                         single integer: the number of ledger lines
#                         already consumed. Missing -> 0. Because the
#                         ledger is append-only and lines are appended in
#                         ts order and never edited, a line count is an
#                         exact, cheap cursor. If the ledger now has FEWER
#                         lines than the cursor, the cursor is stale (a
#                         reset/rebuilt store) — warn on stderr and
#                         reprocess from 0.
#   conflicts:            <data-dir>/attention/learn-conflicts.tsv —
#                         header-less TSV, one row per held/resolved
#                         conflict case:
#                           case<TAB>status<TAB>first_ts<TAB>first_to<TAB>second_ts<TAB>second_to
#                         case   = "<slug>-<type>" (matches feedback-to-
#                                  evals.sh's case-directory naming)
#                         status = held | resolved
#                         Rewritten atomically (tmp + mv) only when it
#                         changes.
#
# Conflict rule (applied within one sweep's batch of NEW lines, grouped by
# (type, slug), compared consecutively in ts order): two lines A (earlier)
# and B (later) with different non-empty `to` values are a CONFLICT unless
# B.from == A.to, in which case they are a CHAIN (the user changed their
# mind through the system, having already seen A applied) and latest wins.
# A conflicting pair marks the whole case HELD for that pair (the first
# conflicting pair found is what gets recorded).
#
# Resolution rule: a case that is currently `held` in learn-conflicts.tsv
# and receives new correction line(s) this sweep whose own batch is
# itself conflict-free flips to `resolved` (the user spoke again, cleanly).
# If its new lines conflict again, it stays `held` (row updated with the
# new pair). Held cases with no new lines this sweep are left untouched
# (still held). Conflicts are NEVER auto-resolved by picking "latest wins"
# — only the user speaking again, unambiguously, resolves a hold.
#
# Held cases are excluded from the generated eval suite for this sweep via
# feedback-to-evals.sh's `--exclude` flag, so a disputed correction never
# gets baked into a regression case teaching the wrong answer.
#
# Exit codes:
#   0  success (including "nothing new")
#   2  usage/arg error, jq missing, or bad --data-dir
#   <k> feedback-to-evals.sh's own exit code, propagated verbatim when it
#      fails — the cursor is NOT advanced in that case, so the next sweep
#      retries the same batch.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
FEEDBACK_TO_EVALS="${REPO_ROOT}/packages/ingestion/scripts/feedback-to-evals.sh"

die() {
    printf 'learn-sweep: %s\n' "$1" >&2
    exit "${2:-2}"
}

if [ "$#" -lt 1 ]; then
    die "usage: learn-sweep.sh <store-dir> --data-dir <data-dir> [--dry-run]" 2
fi

store_dir="$1"; shift
data_dir=""
dry_run=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --data-dir) data_dir="${2:-}"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        *) die "unknown argument: $1" 2 ;;
    esac
done

[ -n "$store_dir" ] || die "missing <store-dir>" 2
[ -n "$data_dir" ] || die "missing --data-dir" 2

command -v jq >/dev/null 2>&1 || die "jq is required" 2

case "$store_dir" in
    /*) : ;;
    *) store_dir="$(cd "$store_dir" && pwd)" ;;
esac
mkdir -p "$data_dir" || die "could not create --data-dir: ${data_dir}" 2
data_dir="$(cd "$data_dir" && pwd)"

ledger="${store_dir}/signals/feedback.jsonl"
attention_dir="${data_dir}/attention"
cursor_file="${attention_dir}/learn-sweep.cursor"
conflicts_file="${attention_dir}/learn-conflicts.tsv"

# NOTE: attention_dir is only created lazily, right before a write — a
# --dry-run must leave the data dir untouched (writes nothing at all).

# --- read cursor (missing/invalid -> 0) ---
c=0
if [ -f "$cursor_file" ]; then
    raw_c="$(cat "$cursor_file" 2>/dev/null | tr -d '[:space:]')"
    case "$raw_c" in
        ''|*[!0-9]*) c=0 ;;
        *) c="$raw_c" ;;
    esac
fi

# --- count ledger lines (missing -> 0); a trailing-newline-less file would
#     undercount with `wc -l`, so use awk's NR instead ---
n=0
if [ -f "$ledger" ]; then
    n="$(awk 'END{print NR}' "$ledger" 2>/dev/null)"
    [ -n "$n" ] || n=0
fi

if [ "$n" -lt "$c" ]; then
    printf 'learn-sweep: WARN ledger shorter than cursor (%s < %s); resetting cursor to 0\n' "$n" "$c" >&2
    c=0
fi

h_new=$((n - c))

# --- extract this sweep's new lines and, from them, the corrections ---
new_lines_file="$(mktemp "${TMPDIR:-/tmp}/ra-learn-sweep-new.XXXXXX")"
batch_tsv="$(mktemp "${TMPDIR:-/tmp}/ra-learn-sweep-batch.XXXXXX")"
trap 'rm -f "$new_lines_file" "$batch_tsv"' EXIT

: > "$new_lines_file"
: > "$batch_tsv"

if [ "$h_new" -gt 0 ] && [ -f "$ledger" ]; then
    sed -n "$((c + 1)),${n}p" "$ledger" > "$new_lines_file"
fi

if [ -s "$new_lines_file" ]; then
    jq -s -r '
        [ .[]
          | select(.type == "tier-correction" or .type == "kind-correction")
          | select(.target | startswith("person:"))
          | {type, slug: (.target | sub("^person:"; "")), ts, from: (.from // ""), to: (.to // "")}
        ]
        | group_by(.type + "|" + .slug)
        | map(
            (sort_by(.ts)) as $g
            | ($g[0].type) as $type
            | ($g[0].slug) as $slug
            | (reduce range(0; ($g | length) - 1) as $i
                ({conflict: false, pair: null};
                  if .conflict then .
                  else
                    ($g[$i]) as $a | ($g[$i + 1]) as $b
                    | if ($a.to != "") and ($b.to != "") and ($a.to != $b.to) and ($b.from != $a.to)
                      then {conflict: true, pair: {ft: $a.ts, fto: $a.to, st: $b.ts, sto: $b.to}}
                      else .
                      end
                  end
                )
              ) as $res
            | [$slug, $type, ($res.conflict | tostring),
               ($res.pair.ft // ""), ($res.pair.fto // ""),
               ($res.pair.st // ""), ($res.pair.sto // "")]
          )
        | .[]
        | @tsv
    ' "$new_lines_file" > "$batch_tsv" 2>/dev/null
fi

# --- merge batch into the conflicts file ---
working_file="$(mktemp "${TMPDIR:-/tmp}/ra-learn-sweep-conflicts.XXXXXX")"
trap 'rm -f "$new_lines_file" "$batch_tsv" "$working_file"' EXIT

if [ -f "$conflicts_file" ]; then
    cp "$conflicts_file" "$working_file"
else
    : > "$working_file"
fi

batch_case_count=0
batch_conflict_count=0

if [ -s "$batch_tsv" ]; then
    while IFS="$(printf '\t')" read -r slug type conflict ft fto st sto; do
        [ -n "$slug" ] || continue
        case_name="${slug}-${type}"
        batch_case_count=$((batch_case_count + 1))

        old_row="$(awk -F'\t' -v c="$case_name" '$1==c{print; exit}' "$working_file")"

        if [ "$conflict" = "true" ]; then
            batch_conflict_count=$((batch_conflict_count + 1))
            new_row="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$case_name" held "$ft" "$fto" "$st" "$sto")"
            awk -F'\t' -v c="$case_name" '$1!=c' "$working_file" > "${working_file}.tmp"
            mv "${working_file}.tmp" "$working_file"
            printf '%s\n' "$new_row" >> "$working_file"
        else
            if [ -n "$old_row" ]; then
                old_status="$(printf '%s' "$old_row" | awk -F'\t' '{print $2}')"
                if [ "$old_status" = "held" ]; then
                    old_ft="$(printf '%s' "$old_row" | awk -F'\t' '{print $3}')"
                    old_fto="$(printf '%s' "$old_row" | awk -F'\t' '{print $4}')"
                    old_st="$(printf '%s' "$old_row" | awk -F'\t' '{print $5}')"
                    old_sto="$(printf '%s' "$old_row" | awk -F'\t' '{print $6}')"
                    new_row="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$case_name" resolved "$old_ft" "$old_fto" "$old_st" "$old_sto")"
                    awk -F'\t' -v c="$case_name" '$1!=c' "$working_file" > "${working_file}.tmp"
                    mv "${working_file}.tmp" "$working_file"
                    printf '%s\n' "$new_row" >> "$working_file"
                fi
                # already resolved -> leave untouched
            fi
            # never seen before, no conflict -> not tracked here at all
        fi
    done < "$batch_tsv"
fi

sort -o "$working_file" "$working_file" 2>/dev/null || true

held_count="$(awk -F'\t' '$2=="held"{n++} END{print n+0}' "$working_file")"
held_names="$(awk -F'\t' '$2=="held"{print $1}' "$working_file" | tr '\n' ',' | sed 's/,$//')"

k=$((batch_case_count - batch_conflict_count))

# --- (re)generate the learned eval suite ---
n_display=""
fte_ran=0

if [ "$dry_run" -eq 1 ]; then
    n_display="eval cases not regenerated"
else
    if [ -f "$ledger" ] && [ "$n" -gt 0 ]; then
        fte_ran=1
        if [ -n "$held_names" ]; then
            fte_out="$(bash "$FEEDBACK_TO_EVALS" "$store_dir" --data-dir "$data_dir" --exclude "$held_names" 2>&1)"
        else
            fte_out="$(bash "$FEEDBACK_TO_EVALS" "$store_dir" --data-dir "$data_dir" 2>&1)"
        fi
        fte_exit=$?
        if [ "$fte_exit" -ne 0 ]; then
            printf 'learn-sweep: feedback-to-evals failed (exit %s)\n' "$fte_exit" >&2
            printf '%s\n' "$fte_out" >&2
            exit "$fte_exit"
        fi
        eval_cases="$(printf '%s\n' "$fte_out" | sed -n 's/.*cases=\([0-9][0-9]*\).*/\1/p' | head -n 1)"
        [ -n "$eval_cases" ] || eval_cases=0
        n_display="${eval_cases} eval case(s) standing"
    else
        n_display="0 eval case(s) standing"
    fi
fi

# --- write outputs (unless --dry-run) ---
if [ "$dry_run" -eq 0 ]; then
    mkdir -p "$attention_dir" || die "could not create ${attention_dir}" 2

    if [ -f "$conflicts_file" ]; then
        if ! cmp -s "$working_file" "$conflicts_file"; then
            tmp_conflicts="$(mktemp "${attention_dir}/.learn-conflicts.XXXXXX")"
            cp "$working_file" "$tmp_conflicts"
            mv "$tmp_conflicts" "$conflicts_file"
        fi
    else
        if [ -s "$working_file" ]; then
            tmp_conflicts="$(mktemp "${attention_dir}/.learn-conflicts.XXXXXX")"
            cp "$working_file" "$tmp_conflicts"
            mv "$tmp_conflicts" "$conflicts_file"
        fi
    fi

    tmp_cursor="$(mktemp "${attention_dir}/.learn-sweep-cursor.XXXXXX")"
    printf '%s\n' "$n" > "$tmp_cursor"
    mv "$tmp_cursor" "$cursor_file"
fi

# --- digest (always 3 lines) ---
printf 'learn-sweep: learned %d new correction(s) → %s\n' "$k" "$n_display"

if [ "$held_count" -gt 0 ]; then
    printf 'learn-sweep: %d conflict(s) held for you — %s\n' "$held_count" "$conflicts_file"
else
    printf 'learn-sweep: %d conflict(s) held for you\n' "$held_count"
fi

if [ "$dry_run" -eq 1 ]; then
    printf 'learn-sweep: cursor %d → %d (%d new lines) (dry-run)\n' "$c" "$n" "$h_new"
else
    printf 'learn-sweep: cursor %d → %d (%d new lines)\n' "$c" "$n" "$h_new"
fi

exit 0
