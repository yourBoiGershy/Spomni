#!/usr/bin/env bash
# validate-store.sh — schema-and-links checker for a spomni store.
#
# Usage: validate-store.sh [store-dir]   (defaults to ".")
#
# Checks (per packages/core/contracts/*.md):
#   1. Every people/, interactions/, wakeups/ (+ wakeups/signals/) *.md has
#      parseable frontmatter and the contract's required fields.
#   2. Enum fields are valid per contract (wakeup status/origin, signal
#      confidence, person tier).
#   3. Every [[slug]] wiki-link (frontmatter or body) resolves to
#      people/<slug>.md.
#   4. No orphan interactions (every interaction links >=1 existing person).
#   5. No duplicate person slugs (kebab-cased `name` collisions).
#   Plus a contract-called-out rule: every person `## Facts` bullet carries a
#   provenance tag ([told-by-user], [inferred-public-web], or
#   [inferred-from-thread] — the last per plan 32, person.md 1.3.0).
#   6. `profile.md` (singleton, optional — absence is not an error): only the
#      four fixed sections, every bullet provenance-tagged
#      ([stated-by-user]/[observed-from-behavior]), Style notes bullets must
#      be [observed-from-behavior], Signal opt-outs bullets must parse as
#      `<signal-type> — all` or `<signal-type> — [[slug]]`.
#   7. wakeups/ accepts schema_version 1.0.0, 1.1.0, and 1.2.0. When 1.1.0
#      fields (fired-on, dismiss-reason, acted-on, snooze-count, signal-type)
#      are present they are validated, and a 1.1.0 `status: dismissed` entry
#      must carry a non-null dismiss-reason. When 1.2.0 fields (kind,
#      proposed-event, confirmed-on, created-event-id) are present they are
#      validated: `kind` must be `nudge` or `event-proposal`; `kind:
#      event-proposal` requires a `proposed-event` mapping with non-empty
#      title/start/end and >=1 `[[slug]]` attendee, and `proposed-event`
#      present without `kind: event-proposal` is an error; a non-null
#      `created-event-id` requires both a non-null `confirmed-on` and
#      `kind: event-proposal`.
#   8. person.md accepts schema_version 1.0.0, 1.1.0, 1.2.0, and 1.3.0. 1.1.0 kind
#      fields (optional, plan 30): when `kind` is present it must be one of
#      the D3 vocabulary
#      (friend/family/collaborator/professional/community/scheduling/
#      transactional/unsolicited/unknown); `kind_note`, `kind_source`
#      (stated-by-user|derived), and `kind_updated` (YYYY-MM-DD) must then
#      be present and non-empty; `kind_expires`, if present, must be
#      YYYY-MM-DD; `kind: scheduling` requires `kind_expires`. Any
#      `kind_*` field present without `kind` is an error. 1.2.0 `tier_source`
#      (optional, plan 31 D4): when present, `tier` must also be present
#      (else an error), and `tier_source` must be `derived` or
#      `stated-by-user`.
#   9. `user-model.md` (singleton, optional — absence is not an error, per
#      `contracts/user-model.md`): frontmatter parseable; `schema_version`
#      present; `status` in draft|provisional|confirmed (plan 31 D6 adds
#      `provisional`); `provenance` in observed-from-behavior|stated-by-user;
#      pairing (draft or provisional <=> observed-from-behavior +
#      confirmed_at: null; confirmed <=> stated-by-user + confirmed_at a
#      date); `revision` a non-negative integer; `derived_at` a date; only
#      the four fixed `## ` sections, in order (Investment mix, Protected
#      time, Season, Revealed vs stated); `## Investment mix` has exactly
#      the five axis lines (business/friends/family/community/
#      transactional), each with a weight in [0, 1].
#  10. `index/embeddings.jsonl` (optional, per `contracts/embeddings-index.md`):
#      each non-empty line must be valid JSON with a `slug` resolving to
#      people/<slug>.md, a non-empty `model`, an integer `dims` > 0, a
#      `vector` array of numbers whose length equals `dims` and whose L2
#      norm is within 1e-6 of 1.0 (or exactly 0), a non-empty
#      `embedded_at`, and a 64-hex-char `content_hash`.
#
# Output: one finding per line, "path/to/file.md:LINE: message", to stdout.
# Exit 0 and "store clean: N files checked" when clean; exit 1 otherwise.
#
# Portable to bash 3.2: no associative arrays, no mapfile.

set -u
# Force the C locale for every regex/glob/case-class comparison and
# collation in this script (chunk 38 round-3): measurably cheaper at
# 10000+ files, and every fixture is plain ASCII so there is no
# behavior change — verified byte-identical against the original
# script on fixtures/store, fixtures/corrupted, and a 1000/10000
# scale store.
export LC_ALL=C

store_dir="${1:-.}"

findings=0
files_checked=0

report() {
    # $1 = file, $2 = line, $3 = message
    printf '%s:%s: %s\n' "$1" "$2" "$3"
    findings=$((findings + 1))
}

kebab() {
    # kebab-case a display name, e.g. "Dana Whitfield" -> "dana-whitfield"
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# Buckets people slugs by a cheap 2-character hash so check_links_resolve's
# membership test scans a short per-bucket string instead of one giant
# "|slug1|slug2|...|" string that grows with the whole store's people count
# (chunk 38 round-3: at 1000 people that global-string scan was O(people) per
# link, done once per link in every interactions/wakeups/signals file — the
# long pole at 1000/10000 scale). PEOPLE_BUCKETS is a plain indexed array
# (bash 3.2 has no associative arrays), sized generously (37*37 = 1369
# buckets from two base-37 "digits") so the average chain stays tiny even at
# 1000+ people. hash_bucket() dispatches on characters via `case` (a
# printf -v '%d' "'$c" per-character ordinal conversion measured slower at
# this call volume — ~2000 lookups/file-batch — than plain `case` matching).
PEOPLE_BUCKETS=()

hash_bucket() {
    # Sets global HASH_BUCKET to a 0..HASH_BUCKET_COUNT-1 bucket index for
    # $1, derived from its first two characters via pure-bash `case` pattern
    # matching (no printf/external-process char-to-ordinal conversion, which
    # measured as the more expensive approach at this call volume).
    local s="$1"
    local c1="${s:0:1}" c2="${s:1:1}" v1 v2
    case "${c1}" in
        a) v1=0 ;;
        b) v1=1 ;;
        c) v1=2 ;;
        d) v1=3 ;;
        e) v1=4 ;;
        f) v1=5 ;;
        g) v1=6 ;;
        h) v1=7 ;;
        i) v1=8 ;;
        j) v1=9 ;;
        k) v1=10 ;;
        l) v1=11 ;;
        m) v1=12 ;;
        n) v1=13 ;;
        o) v1=14 ;;
        p) v1=15 ;;
        q) v1=16 ;;
        r) v1=17 ;;
        s) v1=18 ;;
        t) v1=19 ;;
        u) v1=20 ;;
        v) v1=21 ;;
        w) v1=22 ;;
        x) v1=23 ;;
        y) v1=24 ;;
        z) v1=25 ;;
        0) v1=26 ;;
        1) v1=27 ;;
        2) v1=28 ;;
        3) v1=29 ;;
        4) v1=30 ;;
        5) v1=31 ;;
        6) v1=32 ;;
        7) v1=33 ;;
        8) v1=34 ;;
        9) v1=35 ;;
        *) v1=36 ;;
    esac
    case "${c2}" in
        a) v2=0 ;;
        b) v2=1 ;;
        c) v2=2 ;;
        d) v2=3 ;;
        e) v2=4 ;;
        f) v2=5 ;;
        g) v2=6 ;;
        h) v2=7 ;;
        i) v2=8 ;;
        j) v2=9 ;;
        k) v2=10 ;;
        l) v2=11 ;;
        m) v2=12 ;;
        n) v2=13 ;;
        o) v2=14 ;;
        p) v2=15 ;;
        q) v2=16 ;;
        r) v2=17 ;;
        s) v2=18 ;;
        t) v2=19 ;;
        u) v2=20 ;;
        v) v2=21 ;;
        w) v2=22 ;;
        x) v2=23 ;;
        y) v2=24 ;;
        z) v2=25 ;;
        0) v2=26 ;;
        1) v2=27 ;;
        2) v2=28 ;;
        3) v2=29 ;;
        4) v2=30 ;;
        5) v2=31 ;;
        6) v2=32 ;;
        7) v2=33 ;;
        8) v2=34 ;;
        9) v2=35 ;;
        *) v2=36 ;;
    esac
    HASH_BUCKET=$(( v1 * 37 + v2 ))
}

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

people_slugs_file="$work_dir/people_slugs.txt"
kebab_map_file="$work_dir/kebab_map.txt"
: > "$people_slugs_file"
: > "$kebab_map_file"

# ---------------------------------------------------------------------------
# Frontmatter helpers
#
# Perf note (chunk 38 / plan 2026-08-30-38): the original implementation
# spawned an awk and/or sed subprocess per field per file (O(files x fields)
# process spawns). Every helper below instead reads each file ONCE into the
# global FILE_LINES array (ensure_file_lines, memoized per file) and does all
# field/line extraction with bash builtins (parameter expansion, [[ =~ ]],
# case) — no per-field process spawn. Output/verdicts are unchanged; only the
# mechanism moved from external tools to bash. A few genuinely O(1)-per-file
# operations (all_links_in_file's grep+sort -u) are left as-is.
# ---------------------------------------------------------------------------

FILE_LINES=()
FILE_LINE_COUNT=0
CURRENT_FILE_LINES_PATH=""

# Loads $1 into the global FILE_LINES array (1-based) unless it's already
# the currently-cached file. Every helper below calls this first, so callers
# never need to worry about staleness even when they interleave files (e.g.
# the duplicate-slug pass, which revisits already-processed people files).
ensure_file_lines() {
    local file="$1"
    if [ "$file" = "$CURRENT_FILE_LINES_PATH" ]; then
        return 0
    fi
    FILE_LINES=()
    local n=0
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        FILE_LINES[$n]="$line"
    done < "$file"
    FILE_LINE_COUNT=$n
    CURRENT_FILE_LINES_PATH="$file"
}

# Sets global FM_END to the 1-based line number of the closing "---" (empty
# on failure). Every call site reads $FM_END directly instead of capturing
# via command substitution, to avoid a subshell fork per file.
find_frontmatter_end() {
    local file="$1"
    ensure_file_lines "$file"
    FM_END=""
    if [ "${FILE_LINES[1]-}" != "---" ]; then
        return 1
    fi
    local i
    for ((i = 2; i <= FILE_LINE_COUNT; i++)); do
        if [ "${FILE_LINES[$i]}" = "---" ]; then
            FM_END="$i"
            return 0
        fi
    done
    return 1
}

# Reports malformed key:value / list lines inside the frontmatter block.
check_frontmatter_lines_parseable() {
    # (chunk 38 round-3: `case`/parameter-expansion checks instead of
    # `[[ =~ ]]` regex — measured cheaper at this call volume, since this
    # runs on every frontmatter line of every file.)
    local file="$1" s="$2" e="$3"
    ensure_file_lines "$file"
    local i line key
    for ((i = s; i <= e; i++)); do
        line="${FILE_LINES[$i]}"
        # ^[A-Za-z0-9_-]+: — a colon-terminated key made only of those chars
        key="${line%%:*}"
        if [ "$key" != "$line" ] && [ -n "$key" ] && [ -z "${key//[A-Za-z0-9_-]/}" ]; then
            continue
        fi
        case "$line" in
            [[:space:]]*) continue ;;  # ^[[:space:]]
            -*) continue ;;            # ^-
        esac
        if [ -z "${line//[[:space:]]/}" ]; then  # ^[[:space:]]*$ (incl. empty)
            continue
        fi
        report "$file" "$i" "malformed frontmatter line (not a key: value or list line)"
    done
}

# Sets global FOUND_LINE to the line number of a "key:" line inside [s,e]
# (empty on failure). Call sites read $FOUND_LINE directly instead of
# capturing via command substitution, to avoid a subshell fork per field.
find_field_line() {
    local file="$1" s="$2" e="$3" key="$4"
    ensure_file_lines "$file"
    FOUND_LINE=""
    local i
    for ((i = s; i <= e; i++)); do
        if [[ "${FILE_LINES[$i]}" == "${key}:"* ]]; then
            FOUND_LINE="$i"
            return 0
        fi
    done
    return 1
}

require_field() {
    # $1 file $2 s $3 e $4 key -> sets global FOUND_FIELD_LINE to the line
    # number on success (field found). Call sites read $FOUND_FIELD_LINE
    # directly instead of capturing via command substitution — this function
    # is invoked several times per file, so that's one fewer subshell fork
    # per call. (Also inlines find_field_line's scan rather than calling it,
    # to avoid a second fork.)
    local file="$1" s="$2" e="$3" key="$4"
    ensure_file_lines "$file"
    FOUND_FIELD_LINE=""
    local i
    for ((i = s; i <= e; i++)); do
        if [[ "${FILE_LINES[$i]}" == "${key}:"* ]]; then
            FOUND_FIELD_LINE="$i"
            return 0
        fi
    done
    report "$file" "$s" "missing required field: $key"
    return 1
}

# Scalar value of a "key: value" line, quotes stripped. Sets global
# SCALAR_VAL — call sites read it directly instead of capturing via command
# substitution, to avoid a subshell fork per field.
scalar_value() {
    local file="$1" line="$2" key="$3"
    ensure_file_lines "$file"
    local raw="${FILE_LINES[$line]}"
    raw="${raw#${key}:}"
    while [[ "$raw" == [[:space:]]* ]]; do raw="${raw#[[:space:]]}"; done
    while [[ "$raw" == *[[:space:]] ]]; do raw="${raw%[[:space:]]}"; done
    if [[ "$raw" == \"*\" ]] && [ "${#raw}" -ge 2 ]; then
        raw="${raw:1:${#raw}-2}"
    fi
    SCALAR_VAL="$raw"
}

check_enum() {
    # $1 file $2 line $3 key $4 value $5 pipe-separated allowed values
    # (alternatives may carry regex-style backslash-escaped dots, e.g.
    # "1\.0\.0|1\.1\.0" — stripped for the plain-string comparison below;
    # the error message keeps them verbatim, matching the original grep -E
    # implementation's output byte-for-byte.)
    local file="$1" line="$2" key="$3" value="$4" allowed="$5"
    local plain="${allowed//\\/}"
    local -a alts
    IFS='|' read -ra alts <<< "$plain"
    local matched=0
    local alt
    for alt in "${alts[@]}"; do
        if [ "$value" = "$alt" ]; then
            matched=1
            break
        fi
    done
    if [ "$matched" -eq 0 ]; then
        local pretty
        pretty=$(printf '%s' "$allowed" | tr '|' ',')
        report "$file" "$line" "invalid ${key}: '${value}' (expected one of: ${pretty})"
    fi
}

# Lines (with continuation list items) belonging to a key's value block.
extract_field_block() {
    local file="$1" s="$2" e="$3" key="$4"
    ensure_file_lines "$file"
    local i line inblock=0
    for ((i = s; i <= e; i++)); do
        line="${FILE_LINES[$i]}"
        if [[ "$line" == "${key}:"* ]]; then
            printf '%s\n' "$line"
            inblock=1
            continue
        fi
        if [ "$inblock" -eq 1 ]; then
            if [[ "$line" =~ ^[[:space:]]+- ]]; then
                printf '%s\n' "$line"
                continue
            else
                inblock=0
            fi
        fi
    done
}

# Lines belonging to a mapping-valued key's block (indented "subkey: value"
# lines), including the key line itself. E.g. for `proposed-event:` followed
# by indented `title:`/`start:`/... lines.
extract_mapping_block() {
    local file="$1" s="$2" e="$3" key="$4"
    ensure_file_lines "$file"
    local i line inblock=0
    for ((i = s; i <= e; i++)); do
        line="${FILE_LINES[$i]}"
        if [[ "$line" == "${key}:"* ]]; then
            printf '%s\n' "$line"
            inblock=1
            continue
        fi
        if [ "$inblock" -eq 1 ]; then
            if [[ "$line" =~ ^[[:space:]]+[A-Za-z0-9_-]+: ]]; then
                printf '%s\n' "$line"
                continue
            else
                inblock=0
            fi
        fi
    done
}

# Prints the line number of an indented "subkey:" line inside a mapping
# key's block, or nothing.
find_mapping_field_line() {
    local file="$1" s="$2" e="$3" mapkey="$4" subkey="$5"
    ensure_file_lines "$file"
    local i line inblock=0
    for ((i = s; i <= e; i++)); do
        line="${FILE_LINES[$i]}"
        if [[ "$line" == "${mapkey}:"* ]]; then
            inblock=1
            continue
        fi
        if [ "$inblock" -eq 1 ]; then
            if [[ "$line" =~ ^[[:space:]]+[A-Za-z0-9_-]+: ]]; then
                if [[ "$line" =~ ^[[:space:]]+${subkey}: ]]; then
                    printf '%s\n' "$i"
                    return 0
                fi
                continue
            else
                inblock=0
            fi
        fi
    done
    return 1
}

# Scalar value of an indented "  key: value" mapping-block line, quotes
# stripped.
mapping_scalar_value() {
    local file="$1" line="$2" key="$3"
    ensure_file_lines "$file"
    local raw="${FILE_LINES[$line]}"
    while [[ "$raw" == [[:space:]]* ]]; do raw="${raw#[[:space:]]}"; done
    raw="${raw#${key}:}"
    while [[ "$raw" == [[:space:]]* ]]; do raw="${raw#[[:space:]]}"; done
    while [[ "$raw" == *[[:space:]] ]]; do raw="${raw%[[:space:]]}"; done
    if [[ "$raw" == \"*\" ]] && [ "${#raw}" -ge 2 ]; then
        raw="${raw:1:${#raw}-2}"
    fi
    printf '%s\n' "$raw"
}

# Extracts every [[slug]] occurrence from a (possibly multi-line) text blob,
# one per output line, in order of appearance. Pure-bash replacement for
# `grep -oE '\[\[...\]\]' | sed 's/^\[\[//; s/\]\]$//'`.
extract_slugs_from_text() {
    local text="$1"
    local rest="$text"
    while [[ "$rest" =~ \[\[([A-Za-z0-9_-]+)\]\] ]]; do
        printf '%s\n' "${BASH_REMATCH[1]}"
        rest="${rest#*"${BASH_REMATCH[0]}"}"
    done
}

# All [[slug]] links inside a field's value block.
# (inlines extract_field_block's scan + extract_slugs_from_text's regex loop
# rather than calling them via command substitution, to avoid two subshell
# forks on every call.)
# Sets global FIELD_LINKS to a newline-separated list of [[slug]] links
# inside a field's value block (empty if none). Call sites read it directly
# instead of capturing via command substitution, to avoid a subshell fork.
field_links() {
    local file="$1" s="$2" e="$3" key="$4"
    ensure_file_lines "$file"
    local i line inblock=0 block=""
    for ((i = s; i <= e; i++)); do
        line="${FILE_LINES[$i]}"
        if [[ "$line" == "${key}:"* ]]; then
            block="${block}${line}"$'\n'
            inblock=1
            continue
        fi
        if [ "$inblock" -eq 1 ]; then
            if [[ "$line" =~ ^[[:space:]]+- ]]; then
                block="${block}${line}"$'\n'
                continue
            else
                inblock=0
            fi
        fi
    done
    local rest="$block"
    FIELD_LINKS=""
    while [[ "$rest" =~ \[\[([A-Za-z0-9_-]+)\]\] ]]; do
        FIELD_LINKS="${FIELD_LINKS}${BASH_REMATCH[1]}"$'\n'
        rest="${rest#*"${BASH_REMATCH[0]}"}"
    done
}

# All [[slug]] links anywhere in the whole file (frontmatter + body),
# de-duplicated, one per output line, in order of first appearance.
# (inlines extract_slugs_from_text's regex loop for the same reason.)
# All [[slug]] links anywhere in the whole file (frontmatter + body),
# de-duplicated, one per output line, in order of first appearance. Kept as
# a standalone function (unused internally now — see check_links_resolve,
# which inlines the same scan to stay fork-free) in case other callers want
# it later.
all_links_in_file() {
    local file="$1"
    ensure_file_lines "$file"
    local whole=""
    if [ "$FILE_LINE_COUNT" -gt 0 ]; then
        printf -v whole '%s\n' "${FILE_LINES[@]}"
    fi
    local seen_pipe="|" slug rest="$whole"
    while [[ "$rest" =~ \[\[([A-Za-z0-9_-]+)\]\] ]]; do
        slug="${BASH_REMATCH[1]}"
        rest="${rest#*"${BASH_REMATCH[0]}"}"
        if [[ "$seen_pipe" != *"|${slug}|"* ]]; then
            seen_pipe="${seen_pipe}${slug}|"
            printf '%s\n' "$slug"
        fi
    done
}

check_links_resolve() {
    # $1 file -> reports any [[slug]] link that doesn't resolve to
    # people/<slug>.md. Inlines all_links_in_file's whole-file scan and
    # iterates matches directly (no command substitution / here-string),
    # so this whole check runs with zero subshell forks per file.
    local file="$1"
    ensure_file_lines "$file"
    local whole=""
    if [ "$FILE_LINE_COUNT" -gt 0 ]; then
        printf -v whole '%s\n' "${FILE_LINES[@]}"
    fi
    local i seen_pipe="|" slug rest="$whole" link_line
    while [[ "$rest" =~ \[\[([A-Za-z0-9_-]+)\]\] ]]; do
        slug="${BASH_REMATCH[1]}"
        rest="${rest#*"${BASH_REMATCH[0]}"}"
        [[ "$seen_pipe" != *"|${slug}|"* ]] || continue
        seen_pipe="${seen_pipe}${slug}|"
        hash_bucket "$slug"
        if [[ "${PEOPLE_BUCKETS[$HASH_BUCKET]-}" != *"|${slug}|"* ]]; then
            link_line=""
            for ((i = 1; i <= FILE_LINE_COUNT; i++)); do
                if [[ "${FILE_LINES[$i]}" == *"[[${slug}]]"* ]]; then
                    link_line="$i"
                    break
                fi
            done
            [ -n "$link_line" ] || link_line=1
            report "$file" "$link_line" "broken link: [[${slug}]] does not resolve to people/${slug}.md"
        fi
    done
}

# ---------------------------------------------------------------------------
# Pass 0: check required directories exist
# ---------------------------------------------------------------------------

for sub in people interactions wakeups; do
    if [ ! -d "$store_dir/$sub" ]; then
        report "$store_dir/$sub" 1 "missing directory: ${sub}/ not found"
    fi
done

# ---------------------------------------------------------------------------
# Pass 1: people/ — collect slugs first (needed for link resolution), then
# validate each file.
# ---------------------------------------------------------------------------

people_files=()
if [ -d "$store_dir/people" ]; then
    for f in "$store_dir/people"/*.md; do
        [ -e "$f" ] || continue
        base="${f##*/}"
        base="${base%.md}"
        printf '%s\n' "$base" >> "$people_slugs_file"
        hash_bucket "$base"
        PEOPLE_BUCKETS[$HASH_BUCKET]="${PEOPLE_BUCKETS[$HASH_BUCKET]:-|}${base}|"
        people_files+=("$f")
    done
fi

# ---------------------------------------------------------------------------
# One-shot precomputation over every people/*.md file (chunk 38 retry round):
# both the kebab-slug map (for duplicate-slug detection) and the Facts
# provenance-tag findings are computed with a SINGLE awk invocation each
# across all files, instead of one awk/sed/grep spawn per file. Output is
# consumed below at the same points the old per-file checks ran, so ordering
# and message text stay byte-identical.
# ---------------------------------------------------------------------------

if [ "${#people_files[@]}" -gt 0 ]; then
    # kebab-slug map: replicates kebab()'s tr+sed pipeline plus scalar_value's
    # quote/whitespace stripping, restricted to the first "name:" line inside
    # a well-formed frontmatter block (opening "---" on line 1, a later
    # closing "---") — mirrors find_frontmatter_end + require_field "name" +
    # scalar_value's value extraction + kebab()'s casing exactly.
    awk '
        FNR==1 {
            if (fname != "") { finish() }
            fname = FILENAME
            firstline = 1
            infm = 0
            fmend = 0
            namefound = 0
            name = ""
        }
        {
            if (firstline) {
                firstline = 0
                if ($0 == "---") { infm = 1 } else { infm = 0 }
                next
            }
            if (infm && fmend == 0) {
                if ($0 == "---") { fmend = 1; next }
                if (!namefound && $0 ~ /^name:/) {
                    val = $0
                    sub(/^name:/, "", val)
                    gsub(/^[ \t]+/, "", val)
                    gsub(/[ \t]+$/, "", val)
                    if (val ~ /^".*"$/ && length(val) >= 2) {
                        val = substr(val, 2, length(val) - 2)
                    }
                    name = val
                    namefound = 1
                }
            }
        }
        function finish() {
            if (infm && fmend && namefound) {
                k = tolower(name)
                gsub(/[^a-z0-9]+/, "-", k)
                gsub(/^-+/, "", k)
                gsub(/-+$/, "", k)
                print k "\t" fname
            }
        }
        END { finish() }
    ' "${people_files[@]}" >> "$kebab_map_file"

    # Facts provenance-tag findings: replicates the per-file
    # "## Facts" bullet scan + tag-regex check, emitting the exact report()
    # arguments (file, line, message) instead of raw bullet text — the
    # per-file loop below just replays these.
    facts_findings_file="$work_dir/facts_findings.txt"
    awk '
        FNR==1 { infacts = 0 }
        /^## Facts$/ { infacts = 1; next }
        /^## / { infacts = 0 }
        infacts && /^- / {
            if ($0 !~ /^- \*\*\[(told-by-user|inferred-public-web|inferred-from-thread)\]\*\*/) {
                print FILENAME "\t" FNR "\tFacts bullet missing provenance tag ([told-by-user], [inferred-public-web], or [inferred-from-thread])"
            }
        }
    ' "${people_files[@]}" > "$facts_findings_file"

    FACTS_FINDINGS=()
    if [ -s "$facts_findings_file" ]; then
        while IFS= read -r ff_line || [ -n "$ff_line" ]; do
            FACTS_FINDINGS+=("$ff_line")
        done < "$facts_findings_file"
    fi
fi
facts_idx=0

if [ -d "$store_dir/people" ]; then
    for f in "$store_dir/people"/*.md; do
        [ -e "$f" ] || continue
        files_checked=$((files_checked + 1))

        find_frontmatter_end "$f"
        fm_end="$FM_END"
        if [ -z "$fm_end" ]; then
            report "$f" 1 "malformed frontmatter: missing opening/closing ---"
            continue
        fi
        fm_start=2
        fm_body_end=$((fm_end - 1))
        check_frontmatter_lines_parseable "$f" "$fm_start" "$fm_body_end"

        require_field "$f" "$fm_start" "$fm_body_end" "schema_version"
        person_sv_line="$FOUND_FIELD_LINE"
        if [ -n "$person_sv_line" ]; then
            scalar_value "$f" "$person_sv_line" "schema_version"
            person_sv_val="$SCALAR_VAL"
            check_enum "$f" "$person_sv_line" "schema_version" "$person_sv_val" "1\.0\.0|1\.1\.0|1\.2\.0|1\.3\.0"
        fi
        require_field "$f" "$fm_start" "$fm_body_end" "name"
        name_line="$FOUND_FIELD_LINE"
        # (the kebab-slug map entry for this file, if any, was already
        # written by the one-shot awk precomputation above — see
        # "One-shot precomputation" — so there is nothing left to do here.)

        find_field_line "$f" "$fm_start" "$fm_body_end" "tier"
        tier_line="$FOUND_LINE"
        if [ -n "$tier_line" ]; then
            scalar_value "$f" "$tier_line" "tier"
            tier_val="$SCALAR_VAL"
            check_enum "$f" "$tier_line" "tier" "$tier_val" "inner-circle|close|active|dormant"
        fi

        # --- person.md 1.2.0 tier_source (optional, plan 31 D4) ---
        find_field_line "$f" "$fm_start" "$fm_body_end" "tier_source"
        tier_source_line="$FOUND_LINE"
        if [ -n "$tier_source_line" ]; then
            if [ -z "$tier_line" ]; then
                report "$f" "$tier_source_line" "tier_source is set without tier"
            else
                scalar_value "$f" "$tier_source_line" "tier_source"
                tier_source_val="$SCALAR_VAL"
                check_enum "$f" "$tier_source_line" "tier_source" "$tier_source_val" "derived|stated-by-user"
            fi
        fi

        # --- person.md 1.1.0 kind fields (optional, plan 30) ---
        find_field_line "$f" "$fm_start" "$fm_body_end" "kind"
        kind_line="$FOUND_LINE"
        find_field_line "$f" "$fm_start" "$fm_body_end" "kind_note"
        kind_note_line="$FOUND_LINE"
        find_field_line "$f" "$fm_start" "$fm_body_end" "kind_source"
        kind_source_line="$FOUND_LINE"
        find_field_line "$f" "$fm_start" "$fm_body_end" "kind_expires"
        kind_expires_line="$FOUND_LINE"
        find_field_line "$f" "$fm_start" "$fm_body_end" "kind_updated"
        kind_updated_line="$FOUND_LINE"

        if [ -n "$kind_line" ]; then
            scalar_value "$f" "$kind_line" "kind"
            kind_val="$SCALAR_VAL"
            check_enum "$f" "$kind_line" "kind" "$kind_val" "friend|family|collaborator|professional|community|scheduling|transactional|unsolicited|unknown"

            if [ -z "$kind_note_line" ]; then
                report "$f" "$kind_line" "kind is set but missing required field: kind_note"
            else
                scalar_value "$f" "$kind_note_line" "kind_note"
                kind_note_val="$SCALAR_VAL"
                [ -n "$kind_note_val" ] || report "$f" "$kind_note_line" "kind_note must not be empty"
            fi

            if [ -z "$kind_source_line" ]; then
                report "$f" "$kind_line" "kind is set but missing required field: kind_source"
            else
                scalar_value "$f" "$kind_source_line" "kind_source"
                kind_source_val="$SCALAR_VAL"
                check_enum "$f" "$kind_source_line" "kind_source" "$kind_source_val" "stated-by-user|derived"
            fi

            if [ -z "$kind_updated_line" ]; then
                report "$f" "$kind_line" "kind is set but missing required field: kind_updated"
            else
                scalar_value "$f" "$kind_updated_line" "kind_updated"
                kind_updated_val="$SCALAR_VAL"
                if [ -z "$kind_updated_val" ] || ! printf '%s' "$kind_updated_val" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
                    report "$f" "$kind_updated_line" "invalid kind_updated: '${kind_updated_val}' (expected ISO 8601 date YYYY-MM-DD)"
                fi
            fi

            if [ -n "$kind_expires_line" ]; then
                scalar_value "$f" "$kind_expires_line" "kind_expires"
                kind_expires_val="$SCALAR_VAL"
                if [ -n "$kind_expires_val" ] && ! printf '%s' "$kind_expires_val" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
                    report "$f" "$kind_expires_line" "invalid kind_expires: '${kind_expires_val}' (expected ISO 8601 date YYYY-MM-DD)"
                fi
            fi

            if [ "$kind_val" = "scheduling" ] && [ -z "$kind_expires_line" ]; then
                report "$f" "$kind_line" "kind: scheduling requires a kind_expires date"
            fi
        else
            for pair in "kind_note:${kind_note_line}" "kind_source:${kind_source_line}" "kind_expires:${kind_expires_line}" "kind_updated:${kind_updated_line}"; do
                pkey="${pair%%:*}"
                pline="${pair#*:}"
                if [ -n "$pline" ]; then
                    report "$f" "$pline" "${pkey} is set without kind"
                fi
            done
        fi

        # Facts section: every bullet must carry a provenance tag. Findings
        # were precomputed once for all people/*.md files above (see
        # "One-shot precomputation"); replay this file's share of them here,
        # in the same file-grouped, line-ordered form the old per-file
        # awk+grep scan produced.
        while [ "$facts_idx" -lt "${#FACTS_FINDINGS[@]}" ]; do
            ff_entry="${FACTS_FINDINGS[$facts_idx]}"
            ff_path="${ff_entry%%$'\t'*}"
            [ "$ff_path" = "$f" ] || break
            ff_rest="${ff_entry#*$'\t'}"
            ff_line="${ff_rest%%$'\t'*}"
            ff_message="${ff_rest#*$'\t'}"
            report "$f" "$ff_line" "$ff_message"
            facts_idx=$((facts_idx + 1))
        done

        check_links_resolve "$f"
    done
fi

# Duplicate person slugs (kebab-cased name collisions).
if [ -s "$kebab_map_file" ]; then
    sorted=$(sort -k1,1 "$kebab_map_file")
    prev_slug=""
    prev_file=""
    while IFS=$'\t' read -r slug file; do
        [ -n "$slug" ] || continue
        if [ "$slug" = "$prev_slug" ]; then
            find_frontmatter_end "$file"
            find_field_line "$file" 2 "$((FM_END - 1))" "name"
            name_line="$FOUND_LINE"
            [ -n "$name_line" ] || name_line=1
            report "$file" "$name_line" "duplicate person slug '${slug}' also used by ${prev_file}"
        fi
        prev_slug="$slug"
        prev_file="$file"
    done <<EOF
$sorted
EOF
fi

# ---------------------------------------------------------------------------
# Pass 1.5: profile.md (singleton, optional — absence is not an error)
# ---------------------------------------------------------------------------

if [ -f "$store_dir/profile.md" ]; then
    f="$store_dir/profile.md"
    files_checked=$((files_checked + 1))

    find_frontmatter_end "$f"
    fm_end="$FM_END"
    if [ -z "$fm_end" ]; then
        report "$f" 1 "malformed frontmatter: missing opening/closing ---"
    else
        fm_start=2
        fm_body_end=$((fm_end - 1))
        check_frontmatter_lines_parseable "$f" "$fm_start" "$fm_body_end"

        require_field "$f" "$fm_start" "$fm_body_end" "schema_version" > /dev/null

        # Only the four fixed sections are allowed.
        bad_headings=$(awk -v e="$fm_end" '
            NR>e && /^## / { print NR":"$0 }
        ' "$f")
        if [ -n "$bad_headings" ]; then
            while IFS= read -r entry; do
                [ -n "$entry" ] || continue
                ln="${entry%%:*}"
                txt="${entry#*:}"
                case "$txt" in
                    "## Priorities"|"## Cadence wishes"|"## Signal opt-outs"|"## Style notes"|"## Notify") ;;
                    *) report "$f" "$ln" "unexpected section '${txt}' (profile.md allows only Priorities, Cadence wishes, Signal opt-outs, Style notes, Notify)" ;;
                esac
            done <<EOF
$bad_headings
EOF
        fi

        for section in "Priorities" "Cadence wishes" "Signal opt-outs" "Style notes" "Notify"; do
            bullets=$(awk -v header="## ${section}" '
                $0 == header {insec=1; next}
                /^## /{insec=0}
                insec && /^- / { print NR":"$0 }
            ' "$f")
            [ -n "$bullets" ] || continue
            while IFS= read -r entry; do
                [ -n "$entry" ] || continue
                ln="${entry%%:*}"
                txt="${entry#*:}"
                if ! printf '%s' "$txt" | grep -qE '^- \*\*\[(stated-by-user|observed-from-behavior)\]\*\*'; then
                    report "$f" "$ln" "${section} bullet missing provenance tag ([stated-by-user] or [observed-from-behavior])"
                    continue
                fi
                if [ "$section" = "Style notes" ]; then
                    if ! printf '%s' "$txt" | grep -qE '^- \*\*\[observed-from-behavior\]\*\*'; then
                        report "$f" "$ln" "Style notes bullet must be [observed-from-behavior], not [stated-by-user]"
                    fi
                fi
                if [ "$section" = "Signal opt-outs" ]; then
                    rest=$(printf '%s' "$txt" | sed -E 's/^- \*\*\[(stated-by-user|observed-from-behavior)\]\*\*[[:space:]]*//')
                    if ! printf '%s' "$rest" | grep -qE '^[A-Za-z0-9_-]+ — (all|\[\[[A-Za-z0-9_-]+\]\])[[:space:]]*$'; then
                        report "$f" "$ln" "Signal opt-outs bullet malformed (expected '<signal-type> — all' or '<signal-type> — [[slug]]')"
                    fi
                fi
                if [ "$section" = "Notify" ]; then
                    if ! printf '%s' "$txt" | grep -qE '^- \*\*\[stated-by-user\]\*\* (channel|beeper_chat_id|quiet_hours|gmail_address): [^[:space:]]+'; then
                        rest=$(printf '%s' "$txt" | sed -E 's/^- \*\*\[(stated-by-user|observed-from-behavior)\]\*\*[[:space:]]*//')
                        key="${rest%%:*}"
                        report "$f" "$ln" "Notify bullet: unknown key '${key}' (expected channel, beeper_chat_id, quiet_hours, or gmail_address, [stated-by-user] only, non-empty value)"
                    else
                        key=$(printf '%s' "$txt" | sed -E 's/^- \*\*\[stated-by-user\]\*\* ([A-Za-z_]+):.*/\1/')
                        val=$(printf '%s' "$txt" | sed -E 's/^- \*\*\[stated-by-user\]\*\* [A-Za-z_]+:[[:space:]]*//; s/[[:space:]]*\([0-9]{4}-[0-9]{2}-[0-9]{2}\)[[:space:]]*$//; s/[[:space:]]*$//')
                        if [ "$key" = "channel" ]; then
                            if ! printf '%s' "$val" | grep -qE '^(beeper-self|gmail-self|outbox|none)$'; then
                                report "$f" "$ln" "Notify channel value invalid (expected beeper-self, gmail-self, outbox, or none)"
                            fi
                        fi
                        if [ "$key" = "quiet_hours" ]; then
                            if ! printf '%s' "$val" | grep -qE '^[0-2][0-9]:[0-5][0-9]-[0-2][0-9]:[0-5][0-9]$'; then
                                report "$f" "$ln" "Notify quiet_hours value malformed (expected HH:MM-HH:MM)"
                            fi
                        fi
                    fi
                fi
            done <<EOF
$bullets
EOF
        done

        check_links_resolve "$f"
    fi
fi

# ---------------------------------------------------------------------------
# Pass 1.6: user-model.md (singleton, optional — absence is not an error)
# ---------------------------------------------------------------------------

if [ -f "$store_dir/user-model.md" ]; then
    f="$store_dir/user-model.md"
    files_checked=$((files_checked + 1))

    find_frontmatter_end "$f"
    fm_end="$FM_END"
    if [ -z "$fm_end" ]; then
        report "$f" 1 "malformed frontmatter: missing opening/closing ---"
    else
        fm_start=2
        fm_body_end=$((fm_end - 1))
        check_frontmatter_lines_parseable "$f" "$fm_start" "$fm_body_end"

        require_field "$f" "$fm_start" "$fm_body_end" "schema_version" > /dev/null

        require_field "$f" "$fm_start" "$fm_body_end" "status"
        status_line="$FOUND_FIELD_LINE"
        status_val=""
        if [ -n "$status_line" ]; then
            scalar_value "$f" "$status_line" "status"
            status_val="$SCALAR_VAL"
            check_enum "$f" "$status_line" "status" "$status_val" "draft|provisional|confirmed"
        fi

        require_field "$f" "$fm_start" "$fm_body_end" "provenance"
        provenance_line="$FOUND_FIELD_LINE"
        provenance_val=""
        if [ -n "$provenance_line" ]; then
            scalar_value "$f" "$provenance_line" "provenance"
            provenance_val="$SCALAR_VAL"
            check_enum "$f" "$provenance_line" "provenance" "$provenance_val" "observed-from-behavior|stated-by-user"
        fi

        require_field "$f" "$fm_start" "$fm_body_end" "confirmed_at"
        confirmed_at_line="$FOUND_FIELD_LINE"
        confirmed_at_val=""
        if [ -n "$confirmed_at_line" ]; then
            scalar_value "$f" "$confirmed_at_line" "confirmed_at"
            confirmed_at_val="$SCALAR_VAL"
        fi

        if [ -n "$status_line" ] && [ -n "$provenance_line" ] && [ -n "$confirmed_at_line" ]; then
            if [ "$status_val" = "draft" ] || [ "$status_val" = "provisional" ]; then
                if [ "$provenance_val" != "observed-from-behavior" ]; then
                    report "$f" "$status_line" "status: ${status_val} requires provenance: observed-from-behavior (found '${provenance_val}')"
                fi
                if [ "$confirmed_at_val" != "null" ]; then
                    report "$f" "$confirmed_at_line" "status: ${status_val} requires confirmed_at: null (found '${confirmed_at_val}')"
                fi
            elif [ "$status_val" = "confirmed" ]; then
                if [ "$provenance_val" != "stated-by-user" ]; then
                    report "$f" "$status_line" "status: confirmed requires provenance: stated-by-user (found '${provenance_val}')"
                fi
                if [ -z "$confirmed_at_val" ] || [ "$confirmed_at_val" = "null" ] || ! printf '%s' "$confirmed_at_val" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
                    report "$f" "$confirmed_at_line" "status: confirmed requires confirmed_at to be a date (found '${confirmed_at_val}')"
                fi
            fi
        fi

        require_field "$f" "$fm_start" "$fm_body_end" "revision"
        revision_line="$FOUND_FIELD_LINE"
        if [ -n "$revision_line" ]; then
            scalar_value "$f" "$revision_line" "revision"
            revision_val="$SCALAR_VAL"
            if ! printf '%s' "$revision_val" | grep -qE '^[0-9]+$'; then
                report "$f" "$revision_line" "invalid revision: '${revision_val}' (expected non-negative integer)"
            fi
        fi

        require_field "$f" "$fm_start" "$fm_body_end" "derived_at"
        derived_at_line="$FOUND_FIELD_LINE"
        if [ -n "$derived_at_line" ]; then
            scalar_value "$f" "$derived_at_line" "derived_at"
            derived_at_val="$SCALAR_VAL"
            if [ -z "$derived_at_val" ] || ! printf '%s' "$derived_at_val" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
                report "$f" "$derived_at_line" "invalid derived_at: '${derived_at_val}' (expected ISO 8601 date YYYY-MM-DD)"
            fi
        fi

        # Only the four fixed sections, in order.
        headings=$(awk -v e="$fm_end" '
            NR>e && /^## / { print NR":"$0 }
        ' "$f")
        expected_headings="## Investment mix
## Protected time
## Season
## Revealed vs stated"
        actual_headings=""
        if [ -n "$headings" ]; then
            while IFS= read -r entry; do
                [ -n "$entry" ] || continue
                ln="${entry%%:*}"
                txt="${entry#*:}"
                case "$txt" in
                    "## Investment mix"|"## Protected time"|"## Season"|"## Revealed vs stated") ;;
                    *) report "$f" "$ln" "unexpected section '${txt}' (user-model.md allows only Investment mix, Protected time, Season, Revealed vs stated)" ;;
                esac
                if [ -z "$actual_headings" ]; then
                    actual_headings="$txt"
                else
                    actual_headings="${actual_headings}
${txt}"
                fi
            done <<EOF
$headings
EOF
        fi
        if [ -n "$headings" ] && [ "$actual_headings" != "$expected_headings" ]; then
            first_ln=$(printf '%s\n' "$headings" | head -n1 | cut -d: -f1)
            report "$f" "$first_ln" "user-model.md sections out of order (expected Investment mix, Protected time, Season, Revealed vs stated in that order)"
        fi

        # Investment mix: exactly the five axis lines, each with a weight in [0,1].
        mix_lines=$(awk '
            /^## Investment mix$/{inmix=1; next}
            /^## /{inmix=0}
            inmix && /^- / { print NR":"$0 }
        ' "$f")
        for axis in business friends family community transactional; do
            axis_lines=$(printf '%s\n' "$mix_lines" | grep -E ":- ${axis}:")
            axis_count=$(printf '%s\n' "$axis_lines" | grep -cE ":- ${axis}:")
            if [ "$axis_count" -eq 0 ]; then
                anchor_ln=$(printf '%s\n' "$mix_lines" | head -n1 | cut -d: -f1)
                [ -n "$anchor_ln" ] || anchor_ln="$fm_end"
                report "$f" "$anchor_ln" "## Investment mix missing required axis line: ${axis}"
            elif [ "$axis_count" -gt 1 ]; then
                while IFS= read -r entry; do
                    [ -n "$entry" ] || continue
                    ln="${entry%%:*}"
                    report "$f" "$ln" "## Investment mix has duplicate axis line: ${axis}"
                done <<EOF
$axis_lines
EOF
            else
                ln="${axis_lines%%:*}"
                txt="${axis_lines#*:}"
                weight=$(printf '%s' "$txt" | sed -E "s/^- ${axis}:[[:space:]]*//" | sed -E 's/[[:space:]]*—.*$//' | sed -E 's/[[:space:]]+$//')
                if ! printf '%s' "$weight" | grep -qE '^(0(\.[0-9]+)?|1(\.0+)?)$'; then
                    report "$f" "$ln" "## Investment mix ${axis} weight out of range or malformed: '${weight}' (expected a number in [0, 1])"
                fi
            fi
        done
    fi
fi

# ---------------------------------------------------------------------------
# Pass 1.7: index/embeddings.jsonl (optional)
# ---------------------------------------------------------------------------

if [ -f "$store_dir/index/embeddings.jsonl" ]; then
    f="$store_dir/index/embeddings.jsonl"
    ln=0
    seen_slugs_file="$work_dir/embeddings_seen_slugs.txt"
    : > "$seen_slugs_file"
    while IFS= read -r line || [ -n "$line" ]; do
        ln=$((ln + 1))
        [ -n "$(printf '%s' "$line" | tr -d '[:space:]')" ] || continue

        if ! printf '%s' "$line" | jq -e . > /dev/null 2>&1; then
            report "$f" "$ln" "malformed JSON"
            continue
        fi

        e_slug=$(printf '%s' "$line" | jq -r '.slug // empty')
        e_model=$(printf '%s' "$line" | jq -r '.model // empty')
        e_dims=$(printf '%s' "$line" | jq -r 'if (.dims|type) == "number" then (.dims|tostring) else "" end')
        e_embedded_at=$(printf '%s' "$line" | jq -r '.embedded_at // empty')
        e_content_hash=$(printf '%s' "$line" | jq -r '.content_hash // empty')
        e_vector_len=$(printf '%s' "$line" | jq -r 'if (.vector|type) == "array" then (.vector|length) else -1 end')
        e_vector_all_numbers=$(printf '%s' "$line" | jq -r 'if (.vector|type) == "array" then (all(.vector[]; type == "number")) else false end')

        if [ -z "$e_slug" ]; then
            report "$f" "$ln" "missing required field: slug"
        elif [ ! -f "$store_dir/people/${e_slug}.md" ]; then
            report "$f" "$ln" "slug '${e_slug}' does not resolve to people/${e_slug}.md"
        else
            printf '%s\n' "$e_slug" >> "$seen_slugs_file"
        fi

        [ -n "$e_model" ] || report "$f" "$ln" "missing or empty required field: model"

        if [ -z "$e_dims" ]; then
            report "$f" "$ln" "missing or non-integer required field: dims"
        elif [ "$e_dims" -le 0 ] 2>/dev/null; then
            report "$f" "$ln" "invalid dims: '${e_dims}' (expected integer > 0)"
        fi

        if [ "$e_vector_len" = "-1" ]; then
            report "$f" "$ln" "missing or non-array required field: vector"
        elif [ "$e_vector_all_numbers" != "true" ]; then
            report "$f" "$ln" "vector must be an array of numbers"
        else
            if [ -n "$e_dims" ] && [ "$e_vector_len" != "$e_dims" ]; then
                report "$f" "$ln" "vector length (${e_vector_len}) does not match dims (${e_dims})"
            fi

            # Norm rule: |v| must be within 1e-6 of 1.0, unless it is the
            # all-zero vector (norm 0) — the writer's one exemption, per
            # contracts/embeddings-index.md's validation rules.
            e_vector_norm=$(printf '%s' "$line" | jq -r '(.vector | map(. * .) | add | sqrt)')
            norm_ok=$(awk -v n="$e_vector_norm" 'BEGIN {
                d = n - 1; if (d < 0) d = -d;
                if (n == 0 || d <= 1e-6) print "yes"; else print "no"
            }')
            if [ "$norm_ok" != "yes" ]; then
                report "$f" "$ln" "vector is not unit-normalized: |v| = ${e_vector_norm} (expected 1 ± 1e-6, or 0)"
            fi
        fi

        [ -n "$e_embedded_at" ] || report "$f" "$ln" "missing or empty required field: embedded_at"

        if ! printf '%s' "$e_content_hash" | grep -qE '^[0-9a-fA-F]{64}$'; then
            report "$f" "$ln" "invalid content_hash: expected 64 hex characters"
        fi
    done < "$f"

    if [ -s "$seen_slugs_file" ]; then
        dup_slugs=$(sort "$seen_slugs_file" | uniq -d)
        if [ -n "$dup_slugs" ]; then
            while IFS= read -r dslug; do
                [ -n "$dslug" ] || continue
                report "$f" 1 "duplicate slug '${dslug}' appears on more than one line"
            done <<EOF
$dup_slugs
EOF
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Pass 2: interactions/
# ---------------------------------------------------------------------------

if [ -d "$store_dir/interactions" ]; then
    for f in "$store_dir/interactions"/*.md; do
        [ -e "$f" ] || continue
        files_checked=$((files_checked + 1))

        find_frontmatter_end "$f"
        fm_end="$FM_END"
        if [ -z "$fm_end" ]; then
            report "$f" 1 "malformed frontmatter: missing opening/closing ---"
            continue
        fi
        fm_start=2
        fm_body_end=$((fm_end - 1))
        check_frontmatter_lines_parseable "$f" "$fm_start" "$fm_body_end"

        require_field "$f" "$fm_start" "$fm_body_end" "schema_version" > /dev/null
        require_field "$f" "$fm_start" "$fm_body_end" "date" > /dev/null
        require_field "$f" "$fm_start" "$fm_body_end" "source-capture" > /dev/null

        require_field "$f" "$fm_start" "$fm_body_end" "people"
        people_line="$FOUND_FIELD_LINE"
        if [ -n "$people_line" ]; then
            field_links "$f" "$fm_start" "$fm_body_end" "people"
            people_links="$FIELD_LINKS"
            if [ -z "$people_links" ]; then
                report "$f" "$people_line" "orphan interaction: no people linked"
            fi
        fi

        check_links_resolve "$f"
    done
fi

# ---------------------------------------------------------------------------
# Pass 3: wakeups/ (top-level entries only; wakeups/signals/ handled below)
# ---------------------------------------------------------------------------

if [ -d "$store_dir/wakeups" ]; then
    for f in "$store_dir/wakeups"/*.md; do
        [ -e "$f" ] || continue
        files_checked=$((files_checked + 1))

        find_frontmatter_end "$f"
        fm_end="$FM_END"
        if [ -z "$fm_end" ]; then
            report "$f" 1 "malformed frontmatter: missing opening/closing ---"
            continue
        fi
        fm_start=2
        fm_body_end=$((fm_end - 1))
        check_frontmatter_lines_parseable "$f" "$fm_start" "$fm_body_end"

        require_field "$f" "$fm_start" "$fm_body_end" "schema_version"
        sv_line="$FOUND_FIELD_LINE"
        sv_val=""
        if [ -n "$sv_line" ]; then
            scalar_value "$f" "$sv_line" "schema_version"
            sv_val="$SCALAR_VAL"
            check_enum "$f" "$sv_line" "schema_version" "$sv_val" "1\.0\.0|1\.1\.0|1\.2\.0"
        fi
        require_field "$f" "$fm_start" "$fm_body_end" "id" > /dev/null
        require_field "$f" "$fm_start" "$fm_body_end" "due" > /dev/null
        require_field "$f" "$fm_start" "$fm_body_end" "why" > /dev/null

        require_field "$f" "$fm_start" "$fm_body_end" "people"
        people_line="$FOUND_FIELD_LINE"
        if [ -n "$people_line" ]; then
            field_links "$f" "$fm_start" "$fm_body_end" "people"
            people_links="$FIELD_LINKS"
            if [ -z "$people_links" ]; then
                report "$f" "$people_line" "wakeup has no people linked"
            fi
        fi

        require_field "$f" "$fm_start" "$fm_body_end" "status"
        status_line="$FOUND_FIELD_LINE"
        status_val=""
        if [ -n "$status_line" ]; then
            scalar_value "$f" "$status_line" "status"
            status_val="$SCALAR_VAL"
            check_enum "$f" "$status_line" "status" "$status_val" "pending|fired|snoozed|dismissed"
        fi

        require_field "$f" "$fm_start" "$fm_body_end" "origin"
        origin_line="$FOUND_FIELD_LINE"
        origin_val=""
        if [ -n "$origin_line" ]; then
            scalar_value "$f" "$origin_line" "origin"
            origin_val="$SCALAR_VAL"
            check_enum "$f" "$origin_line" "origin" "$origin_val" "user-ask|signal|standing"
        fi

        if [ "$origin_val" = "signal" ]; then
            find_field_line "$f" "$fm_start" "$fm_body_end" "source-signal"
            src_line="$FOUND_LINE"
            if [ -z "$src_line" ]; then
                report "$f" "$origin_line" "origin: signal requires a non-null source-signal"
            else
                scalar_value "$f" "$src_line" "source-signal"
                src_val="$SCALAR_VAL"
                if [ -z "$src_val" ] || [ "$src_val" = "null" ]; then
                    report "$f" "$src_line" "origin: signal requires a non-null source-signal"
                fi
            fi
        fi

        # --- schema_version 1.1.0 fields (validated only when present) ---
        find_field_line "$f" "$fm_start" "$fm_body_end" "fired-on"
        fired_on_line="$FOUND_LINE"
        if [ -n "$fired_on_line" ]; then
            scalar_value "$f" "$fired_on_line" "fired-on"
            fired_on_val="$SCALAR_VAL"
            if [ -n "$fired_on_val" ] && [ "$fired_on_val" != "null" ]; then
                if ! printf '%s' "$fired_on_val" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
                    report "$f" "$fired_on_line" "invalid fired-on: '${fired_on_val}' (expected ISO 8601 date YYYY-MM-DD)"
                fi
            fi
        fi

        find_field_line "$f" "$fm_start" "$fm_body_end" "dismiss-reason"
        dismiss_reason_line="$FOUND_LINE"
        dismiss_reason_val=""
        if [ -n "$dismiss_reason_line" ]; then
            scalar_value "$f" "$dismiss_reason_line" "dismiss-reason"
            dismiss_reason_val="$SCALAR_VAL"
            if [ -n "$dismiss_reason_val" ] && [ "$dismiss_reason_val" != "null" ]; then
                check_enum "$f" "$dismiss_reason_line" "dismiss-reason" "$dismiss_reason_val" "not-now|not-this-person|not-this-signal-type|already-handled"
            fi
        fi

        find_field_line "$f" "$fm_start" "$fm_body_end" "acted-on"
        acted_on_line="$FOUND_LINE"
        if [ -n "$acted_on_line" ]; then
            scalar_value "$f" "$acted_on_line" "acted-on"
            acted_on_val="$SCALAR_VAL"
            if [ -n "$acted_on_val" ] && [ "$acted_on_val" != "null" ]; then
                check_enum "$f" "$acted_on_line" "acted-on" "$acted_on_val" "true|false"
            fi
        fi

        find_field_line "$f" "$fm_start" "$fm_body_end" "snooze-count"
        snooze_count_line="$FOUND_LINE"
        if [ -n "$snooze_count_line" ]; then
            scalar_value "$f" "$snooze_count_line" "snooze-count"
            snooze_count_val="$SCALAR_VAL"
            if [ -n "$snooze_count_val" ] && [ "$snooze_count_val" != "null" ]; then
                if ! printf '%s' "$snooze_count_val" | grep -qE '^[0-9]+$'; then
                    report "$f" "$snooze_count_line" "invalid snooze-count: '${snooze_count_val}' (expected non-negative integer)"
                fi
            fi
        fi

        find_field_line "$f" "$fm_start" "$fm_body_end" "signal-type"
        signal_type_line="$FOUND_LINE"
        if [ -n "$signal_type_line" ]; then
            scalar_value "$f" "$signal_type_line" "signal-type"
            signal_type_val="$SCALAR_VAL"
            if [ -n "$signal_type_val" ] && [ "$signal_type_val" != "null" ]; then
                if ! printf '%s' "$signal_type_val" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$'; then
                    report "$f" "$signal_type_line" "invalid signal-type: '${signal_type_val}' (expected non-empty kebab-case)"
                fi
            fi
        fi

        if [ "$sv_val" = "1.1.0" ] && [ "$status_val" = "dismissed" ]; then
            if [ -z "$dismiss_reason_val" ] || [ "$dismiss_reason_val" = "null" ]; then
                report "$f" "$status_line" "status: dismissed at schema_version 1.1.0 requires a non-null dismiss-reason"
            fi
        fi

        # --- schema_version 1.2.0 fields (validated only when present) ---
        find_field_line "$f" "$fm_start" "$fm_body_end" "kind"
        kind_line="$FOUND_LINE"
        kind_val=""
        if [ -n "$kind_line" ]; then
            scalar_value "$f" "$kind_line" "kind"
            kind_val="$SCALAR_VAL"
            if [ -n "$kind_val" ] && [ "$kind_val" != "null" ]; then
                check_enum "$f" "$kind_line" "kind" "$kind_val" "nudge|event-proposal"
            fi
        fi

        find_field_line "$f" "$fm_start" "$fm_body_end" "proposed-event"
        proposed_event_line="$FOUND_LINE"
        pe_present=0
        if [ -n "$proposed_event_line" ]; then
            scalar_value "$f" "$proposed_event_line" "proposed-event"
            pe_val="$SCALAR_VAL"
            if [ -n "$pe_val" ] && [ "$pe_val" != "null" ]; then
                pe_present=1
            else
                pe_block=$(extract_mapping_block "$f" "$fm_start" "$fm_body_end" "proposed-event")
                pe_block_body=$(printf '%s\n' "$pe_block" | tail -n +2)
                if [ -n "$(printf '%s' "$pe_block_body" | tr -d '[:space:]')" ]; then
                    pe_present=1
                fi
            fi
        fi

        if [ "$pe_present" -eq 1 ]; then
            if [ "$kind_val" != "event-proposal" ]; then
                report "$f" "$proposed_event_line" "proposed-event present without kind: event-proposal"
            fi

            title_line=$(find_mapping_field_line "$f" "$fm_start" "$fm_body_end" "proposed-event" "title")
            if [ -z "$title_line" ]; then
                report "$f" "$proposed_event_line" "proposed-event missing required field: title"
            else
                title_val=$(mapping_scalar_value "$f" "$title_line" "title")
                if [ -z "$title_val" ] || [ "$title_val" = "null" ]; then
                    report "$f" "$title_line" "proposed-event.title must not be empty"
                fi
            fi

            start_line=$(find_mapping_field_line "$f" "$fm_start" "$fm_body_end" "proposed-event" "start")
            if [ -z "$start_line" ]; then
                report "$f" "$proposed_event_line" "proposed-event missing required field: start"
            else
                start_val=$(mapping_scalar_value "$f" "$start_line" "start")
                if [ -z "$start_val" ] || [ "$start_val" = "null" ]; then
                    report "$f" "$start_line" "proposed-event.start must not be empty"
                fi
            fi

            end_line=$(find_mapping_field_line "$f" "$fm_start" "$fm_body_end" "proposed-event" "end")
            if [ -z "$end_line" ]; then
                report "$f" "$proposed_event_line" "proposed-event missing required field: end"
            else
                end_val=$(mapping_scalar_value "$f" "$end_line" "end")
                if [ -z "$end_val" ] || [ "$end_val" = "null" ]; then
                    report "$f" "$end_line" "proposed-event.end must not be empty"
                fi
            fi

            attendees_line=$(find_mapping_field_line "$f" "$fm_start" "$fm_body_end" "proposed-event" "attendees")
            if [ -z "$attendees_line" ]; then
                report "$f" "$proposed_event_line" "proposed-event missing required field: attendees"
            else
                attendees_val=$(mapping_scalar_value "$f" "$attendees_line" "attendees")
                attendee_links=$(printf '%s' "$attendees_val" | grep -oE '\[\[[A-Za-z0-9_-]+\]\]')
                if [ -z "$attendee_links" ]; then
                    report "$f" "$attendees_line" "proposed-event.attendees requires at least one [[slug]] attendee"
                fi
            fi
        elif [ "$kind_val" = "event-proposal" ]; then
            report "$f" "$fm_start" "kind: event-proposal requires a proposed-event mapping"
        fi

        find_field_line "$f" "$fm_start" "$fm_body_end" "confirmed-on"
        confirmed_on_line="$FOUND_LINE"
        confirmed_on_val=""
        if [ -n "$confirmed_on_line" ]; then
            scalar_value "$f" "$confirmed_on_line" "confirmed-on"
            confirmed_on_val="$SCALAR_VAL"
            if [ -n "$confirmed_on_val" ] && [ "$confirmed_on_val" != "null" ]; then
                if ! printf '%s' "$confirmed_on_val" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
                    report "$f" "$confirmed_on_line" "invalid confirmed-on: '${confirmed_on_val}' (expected ISO 8601 date YYYY-MM-DD)"
                fi
            fi
        fi

        find_field_line "$f" "$fm_start" "$fm_body_end" "created-event-id"
        created_event_id_line="$FOUND_LINE"
        created_event_id_val=""
        if [ -n "$created_event_id_line" ]; then
            scalar_value "$f" "$created_event_id_line" "created-event-id"
            created_event_id_val="$SCALAR_VAL"
        fi

        if [ -n "$created_event_id_val" ] && [ "$created_event_id_val" != "null" ]; then
            if [ -z "$confirmed_on_val" ] || [ "$confirmed_on_val" = "null" ]; then
                report "$f" "$created_event_id_line" "created-event-id set without a non-null confirmed-on"
            fi
            if [ "$kind_val" != "event-proposal" ]; then
                report "$f" "$created_event_id_line" "created-event-id set on an entry that is not kind: event-proposal"
            fi
        fi

        check_links_resolve "$f"
    done
fi

# ---------------------------------------------------------------------------
# Pass 4: wakeups/signals/ (signal-event contract)
# ---------------------------------------------------------------------------

if [ -d "$store_dir/wakeups/signals" ]; then
    for f in "$store_dir/wakeups/signals"/*.md; do
        [ -e "$f" ] || continue
        files_checked=$((files_checked + 1))

        find_frontmatter_end "$f"
        fm_end="$FM_END"
        if [ -z "$fm_end" ]; then
            report "$f" 1 "malformed frontmatter: missing opening/closing ---"
            continue
        fi
        fm_start=2
        fm_body_end=$((fm_end - 1))
        check_frontmatter_lines_parseable "$f" "$fm_start" "$fm_body_end"

        require_field "$f" "$fm_start" "$fm_body_end" "schema_version" > /dev/null
        require_field "$f" "$fm_start" "$fm_body_end" "id" > /dev/null
        require_field "$f" "$fm_start" "$fm_body_end" "type" > /dev/null
        require_field "$f" "$fm_start" "$fm_body_end" "evidence" > /dev/null
        require_field "$f" "$fm_start" "$fm_body_end" "detected_at" > /dev/null

        require_field "$f" "$fm_start" "$fm_body_end" "person"
        person_line="$FOUND_FIELD_LINE"
        if [ -n "$person_line" ]; then
            field_links "$f" "$fm_start" "$fm_body_end" "person"
            person_links="$FIELD_LINKS"
            if [ -z "$person_links" ]; then
                report "$f" "$person_line" "signal event has no person linked"
            fi
        fi

        require_field "$f" "$fm_start" "$fm_body_end" "confidence"
        conf_line="$FOUND_FIELD_LINE"
        if [ -n "$conf_line" ]; then
            scalar_value "$f" "$conf_line" "confidence"
            conf_val="$SCALAR_VAL"
            check_enum "$f" "$conf_line" "confidence" "$conf_val" "low|medium|high"
        fi

        check_links_resolve "$f"
    done
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

if [ "$findings" -eq 0 ]; then
    echo "store clean: ${files_checked} files checked"
    exit 0
else
    exit 1
fi
