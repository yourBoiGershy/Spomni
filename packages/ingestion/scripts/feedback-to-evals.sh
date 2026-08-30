#!/usr/bin/env bash
# feedback-to-evals.sh — turns every tier-correction/kind-correction line
# in <store-dir>/signals/feedback.jsonl into a T3 regression eval case
# under the private data dir: "the cost of re-explaining is paid once" —
# once the user corrects a kind or tier, a case proves that correction
# still holds against a later `review tiers` pass.
#
# Reads: packages/core/contracts/eval-case.md 1.3.0 (case shape,
# RA_EVAL_PRIVATE_MANIFEST mode), packages/core/contracts/feedback-event.md
# 1.0.0 (ledger shape), packages/ingestion/skills/review-tiers/SKILL.md
# (Step 3's write rules — the "sticky" behavior this generates a proof
# for), plan 34 D4/U20.
#
# Usage:
#   feedback-to-evals.sh <store-dir> --data-dir <data-dir>
#
# Behavior:
#   - Reads <store-dir>/signals/feedback.jsonl (missing/empty -> no
#     corrections).
#   - Keeps only lines with type tier-correction|kind-correction and
#     target person:<slug>; when several exist for the same (slug, type),
#     only the LATEST one (by `ts`) survives.
#   - A correction whose `to` is null (a --clear) is skipped — there is no
#     stated value for a "this sticks" case to assert.
#   - For each surviving correction, (re)generates
#     <data-dir>/evals/feedback/cases/<slug>-<type>/ (T3, eval-case@1.3.0):
#       before/people/<slug>.md               copied from the store
#       before/interactions/*.md              this person's filed
#                                              interactions (grep [[slug]])
#       before/user-model.md                  copied if present
#       before/profile.md                     copied if present
#       before/data-ingestion/evidence.jsonl  this person's fresh
#                                              derive-evidence.sh line
#       prompt.md                             review-tiers Step-3-only,
#                                              scoped to this one person
#       graders/01-stated-holds.sh             asserts the corrected
#                                              field/source survive
#       expected/README.md                    placeholder (grading is by
#                                              graders/, not a byte diff;
#                                              `expected` is still
#                                              required by eval-case.md)
#   - Rewrites <data-dir>/evals/feedback/suite.txt: every generated case's
#     absolute path, one per line, sorted by case name.
#   - Idempotent given an unchanged store + ledger: byte-identical output.
#   - No corrections -> prints "feedback-to-evals: no corrections", writes
#     an empty suite.txt, exit 0.
#   - Otherwise prints "feedback-to-evals: cases=<n>".
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

die() {
    printf 'feedback-to-evals.sh: %s\n' "$1" >&2
    exit "${2:-2}"
}

if [ "$#" -lt 1 ]; then
    die "usage: feedback-to-evals.sh <store-dir> --data-dir <data-dir>" 2
fi

store_dir="$1"; shift
data_dir=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --data-dir) data_dir="${2:-}"; shift 2 ;;
        *) die "unknown argument: $1" 2 ;;
    esac
done

[ -n "$store_dir" ] || die "missing <store-dir>" 2
[ -n "$data_dir" ] || die "missing --data-dir" 2

command -v jq >/dev/null 2>&1 || die "jq is required" 2

# resolve to absolute paths (case/store/expected fields must be absolute
# under the private data dir, per eval-case.md's RA_EVAL_PRIVATE_MANIFEST
# mode)
case "$store_dir" in
    /*) : ;;
    *) store_dir="$(cd "$store_dir" && pwd)" ;;
esac
mkdir -p "$data_dir" || die "could not create --data-dir: ${data_dir}" 2
data_dir="$(cd "$data_dir" && pwd)"

feedback_file="${store_dir}/signals/feedback.jsonl"
feedback_dir="${data_dir}/evals/feedback"
cases_dir="${feedback_dir}/cases"
suite_file="${feedback_dir}/suite.txt"

mkdir -p "$cases_dir" || die "could not create ${cases_dir}" 2

# --- dedupe: one row per (type, slug), latest ts wins, sorted for
#     deterministic output. Fields: slug, type, to, text, ts, from. ---
corrections_tsv="$(mktemp "${TMPDIR:-/tmp}/ra-feedback-to-evals.XXXXXX")"
trap 'rm -f "$corrections_tsv"' EXIT

if [ -f "$feedback_file" ]; then
    jq -s -r '
        [.[] | select(.type == "tier-correction" or .type == "kind-correction")
              | select(.target | startswith("person:"))]
        | group_by(.type + "|" + (.target | sub("^person:"; "")))
        | map(sort_by(.ts) | last)
        | sort_by(.type + "|" + (.target | sub("^person:"; "")))
        | .[]
        | [ (.target | sub("^person:"; "")), .type, (.to // ""), (.text // ""), .ts, (.from // "") ]
        | @tsv
    ' "$feedback_file" > "$corrections_tsv" 2>/dev/null
fi

if [ ! -s "$corrections_tsv" ]; then
    printf 'feedback-to-evals: no corrections\n'
    : > "$suite_file"
    exit 0
fi

case_count=0
generated_names="$(mktemp "${TMPDIR:-/tmp}/ra-feedback-to-evals-names.XXXXXX")"
trap 'rm -f "$corrections_tsv" "$generated_names"' EXIT

while IFS="$(printf '\t')" read -r slug type to text ts from; do
    [ -n "$slug" ] || continue
    [ -n "$to" ] || { printf 'feedback-to-evals: skipping %s/%s (to=null, a clear, nothing to assert holds)\n' "$slug" "$type" >&2; continue; }

    person_src="${store_dir}/people/${slug}.md"
    if [ ! -f "$person_src" ]; then
        printf 'feedback-to-evals: skipping %s/%s (no people/%s.md in store)\n' "$slug" "$type" "$slug" >&2
        continue
    fi

    case "$type" in
        tier-correction) field="tier"; source_field="tier_source" ;;
        kind-correction) field="kind"; source_field="kind_source" ;;
        *) continue ;;
    esac

    case_name="${slug}-${type}"
    case_dir="${cases_dir}/${case_name}"
    today="${ts%%T*}"

    rm -rf "$case_dir"
    mkdir -p "$case_dir/before/people" "$case_dir/before/interactions" \
             "$case_dir/before/data-ingestion" "$case_dir/graders" "$case_dir/expected"

    cp "$person_src" "$case_dir/before/people/${slug}.md"

    if [ -d "${store_dir}/interactions" ]; then
        for f in "${store_dir}"/interactions/*.md; do
            [ -f "$f" ] || continue
            if grep -qF "[[${slug}]]" "$f" 2>/dev/null; then
                cp "$f" "$case_dir/before/interactions/"
            fi
        done
    fi

    [ -f "${store_dir}/user-model.md" ] && cp "${store_dir}/user-model.md" "$case_dir/before/user-model.md"
    [ -f "${store_dir}/profile.md" ] && cp "${store_dir}/profile.md" "$case_dir/before/profile.md"

    evidence_script="${SCRIPT_DIR}/derive-evidence.sh"
    if [ -f "$evidence_script" ]; then
        bash "$evidence_script" "$store_dir" --person "$slug" --today "$today" \
            > "$case_dir/before/data-ingestion/evidence.jsonl" 2>/dev/null
    else
        : > "$case_dir/before/data-ingestion/evidence.jsonl"
    fi

    from_disp="${from:-(none)}"
    if [ -n "$text" ]; then
        words_disp=", words: \"${text}\""
    else
        words_disp=""
    fi

    cat > "$case_dir/prompt.md" <<PROMPT
---
tier: skill
store: ${case_dir}/before
expected: ${case_dir}/expected
max-turns: 12
model: haiku
budget-usd: 0.10
---
Act as the \`review-tiers\` skill
(\`packages/ingestion/skills/review-tiers/SKILL.md\`), invoked as
\`review tiers --person ${slug}\`, running **Step 3 (Judge) only** over
\`./store\`. Steps 1 and 2 already ran off-screen and produced the
pre-seeded \`./store/data-ingestion/evidence.jsonl\` (${slug}'s one
\`derive-evidence.sh\` line) — do not re-derive it, do not run
\`derive-user-model.sh\`, \`embed-people.sh\`, \`cluster-people.sh\`,
\`nearest-confirmed.sh\`, or \`calibrate.sh\` yourself. \`./store/
user-model.md\`, if present, is the confirmed user model. No
\`ranking-weights.json\` is seeded in this fixture — treat every
\`kinds.*\`/\`evidence.*\` prior as its 1.0 default, per
\`relationship-scoring.md\`'s "absent key defaults to 1.0" rule.

Today is **${today}**.

## Recent corrections (judgment prompt input 2b, verbatim)

## Recent corrections
- ${today} person:${slug} — judge said ${field}=${from_disp}, user said ${field}=${to}${words_disp}

These are the user's own words about their relationships; a correction
outranks any prior. Do not restate a correction as a rule for other
people unless the words themselves generalize.

## Inputs, in order (per \`specs/review-tiers.md\`'s judgment prompt
contract)

1. \`./store/user-model.md\`, verbatim, if present.
2. The priors block above (all defaults, per this fixture).
2b. The recent-corrections block above.
3. For \`${slug}\`: \`./store/data-ingestion/evidence.jsonl\`'s one line,
   \`./store/people/${slug}.md\` verbatim, \`./store/interactions/*.md\`'s
   filed summaries (newest first, max 20 — this fixture has fewer),
   \`neighbors: none (embeddings unavailable)\`.
4. The rules, verbatim, from \`relationship-scoring.md\`'s \`## Rules\` —
   in particular:

> **Stated kinds are sticky:** a \`kind_source: stated-by-user\` value is
> never overwritten by a judgment record — the classification pass skips
> people whose current kind is user-stated.

> A user correction writes \`tier_source: stated-by-user\` and sticks —
> never overwritten by a later derived pass.

## Task

Judge \`${slug}\` per the contract above, emit exactly one judgment
record (no other text), append it to
\`./store/data-ingestion/review-judgments/${today}.jsonl\`, then carry
out Step 3's write rules exactly as \`SKILL.md\` specifies:

- If \`${slug}\`'s current \`kind_source\` is already \`stated-by-user\`,
  make **no** \`person-set-kind.sh\` call for them at all — their
  \`kind\` field stays untouched.
- If \`${slug}\`'s current \`tier_source\` is already \`stated-by-user\`,
  still attempt the derived tier write via
  \`person-set-tier.sh ... --source derived\`; when it refuses (exit 2),
  log \`tier: kept stated (${slug})\` and make no further attempt — the
  existing stated tier must be left byte-identical.
- Otherwise, perform the accepted write via \`person-set-kind.sh\`/
  \`person-set-tier.sh --source derived\`, exactly as Step 3 specifies.

Write the files now — do not just describe what you would write.
PROMPT

    cat > "$case_dir/expected/README.md" <<README
# Expected outcome: ${case_name}

This directory exists only to satisfy the \`expected\` frontmatter field
the T3 runner (\`eval-run-skill.sh\`) requires; it is not consumed by
\`RA_GRADER_DIFF\`. Grading is entirely by \`graders/01-stated-holds.sh\`,
which asserts \`./store/people/${slug}.md\` still carries
\`${field}: ${to}\` and \`${source_field}: stated-by-user\` after the
run — this case is a regression proof that the correction recorded in
\`signals/feedback.jsonl\` on ${today} sticks against a later
\`review tiers\` pass, per \`relationship-scoring.md\`'s sticky-stated
rules. Auto-generated by \`packages/ingestion/scripts/feedback-to-evals.sh\`
— do not hand-edit; regenerate instead.
README

    cat > "$case_dir/graders/01-stated-holds.sh" <<GRADER
#!/usr/bin/env bash
# 01-stated-holds.sh — T3 grader for ${case_name}.
# \$1 = path to the worked store dir (the before/ copy after the skill ran).
#
# Hand-derived from the \`signals/feedback.jsonl\` line this case was
# generated from (${slug}, ${type}, to=${to}, ts=${ts}): after the run,
# \`people/${slug}.md\` must still carry \`${field}: ${to}\` and
# \`${source_field}: stated-by-user\` — the correction must stick against
# review-tiers' Step 3 judge/write pass, per relationship-scoring.md's
# sticky-stated rules.

set -u

worked="\${1:-}"
person_file="\${worked}/people/${slug}.md"

if [ ! -f "\$person_file" ]; then
    echo "FAIL: missing \${person_file}"
    exit 1
fi

fail=0

if ! grep -qF '${field}: ${to}' "\$person_file"; then
    echo "FAIL: ${field}: ${to} not found in \${person_file}"
    fail=1
fi

if ! grep -qF '${source_field}: stated-by-user' "\$person_file"; then
    echo "FAIL: ${source_field}: stated-by-user not found in \${person_file}"
    fail=1
fi

if [ "\$fail" -eq 0 ]; then
    echo "PASS: ${slug}'s ${field}=${to} (${source_field}: stated-by-user) held"
    exit 0
fi

exit 1
GRADER
    chmod +x "$case_dir/graders/01-stated-holds.sh"

    printf '%s\n' "$case_name" >> "$generated_names"
    case_count=$((case_count + 1))
done < "$corrections_tsv"

if [ "$case_count" -eq 0 ]; then
    printf 'feedback-to-evals: no corrections\n'
    : > "$suite_file"
    exit 0
fi

{
    printf '# %s/suite.txt — auto-generated by feedback-to-evals.sh (plan 34 D4). Do not hand-edit.\n' "$feedback_dir"
    sort "$generated_names" | while IFS= read -r name; do
        printf '%s/%s\n' "$cases_dir" "$name"
    done
} > "$suite_file"

printf 'feedback-to-evals: cases=%d\n' "$case_count"
exit 0
