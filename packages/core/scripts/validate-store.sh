#!/usr/bin/env bash
# validate-store.sh — schema-and-links checker for a relationship-agent store.
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
#   provenance tag ([told-by-user] or [inferred-public-web]).
#
# Output: one finding per line, "path/to/file.md:LINE: message", to stdout.
# Exit 0 and "store clean: N files checked" when clean; exit 1 otherwise.
#
# Portable to bash 3.2: no associative arrays, no mapfile.

set -u

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

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

people_slugs_file="$work_dir/people_slugs.txt"
kebab_map_file="$work_dir/kebab_map.txt"
: > "$people_slugs_file"
: > "$kebab_map_file"

# ---------------------------------------------------------------------------
# Frontmatter helpers
# ---------------------------------------------------------------------------

# Prints the 1-based line number of the closing "---", or nothing if not
# found / opening marker missing. Sets frontmatter_ok=1/0.
find_frontmatter_end() {
    local file="$1"
    local first_line
    first_line=$(head -n1 "$file")
    if [ "$first_line" != "---" ]; then
        return 1
    fi
    local close_line
    close_line=$(awk 'NR>1 && $0=="---"{print NR; exit}' "$file")
    if [ -z "$close_line" ]; then
        return 1
    fi
    printf '%s\n' "$close_line"
    return 0
}

# Reports malformed key:value / list lines inside the frontmatter block.
check_frontmatter_lines_parseable() {
    local file="$1" s="$2" e="$3"
    local bad_lines
    bad_lines=$(awk -v s="$s" -v e="$e" '
        NR>=s && NR<=e {
            line=$0
            if (line ~ /^[A-Za-z0-9_-]+:/) next
            if (line ~ /^[[:space:]]/) next
            if (line ~ /^-/) next
            if (line ~ /^[[:space:]]*$/) next
            print NR
        }
    ' "$file")
    if [ -n "$bad_lines" ]; then
        local ln
        while IFS= read -r ln; do
            [ -n "$ln" ] || continue
            report "$file" "$ln" "malformed frontmatter line (not a key: value or list line)"
        done <<EOF
$bad_lines
EOF
    fi
}

# Prints the line number of a "key:" line inside [s,e], or nothing.
find_field_line() {
    local file="$1" s="$2" e="$3" key="$4"
    awk -v s="$s" -v e="$e" -v k="^${key}:" 'NR>=s && NR<=e && $0 ~ k {print NR; exit}' "$file"
}

require_field() {
    # $1 file $2 s $3 e $4 key -> prints line number on success (field found)
    local file="$1" s="$2" e="$3" key="$4"
    local line
    line=$(find_field_line "$file" "$s" "$e" "$key")
    if [ -z "$line" ]; then
        report "$file" "$s" "missing required field: $key"
        return 1
    fi
    printf '%s\n' "$line"
    return 0
}

# Scalar value of a "key: value" line, quotes stripped.
scalar_value() {
    local file="$1" line="$2" key="$3"
    sed -n "${line}p" "$file" \
        | sed -E "s/^${key}:[[:space:]]*//" \
        | sed -E 's/[[:space:]]+$//' \
        | sed -E 's/^"(.*)"$/\1/'
}

check_enum() {
    # $1 file $2 line $3 key $4 value $5 pipe-separated allowed values
    local file="$1" line="$2" key="$3" value="$4" allowed="$5"
    if ! printf '%s' "$value" | grep -qE "^(${allowed})\$"; then
        local pretty
        pretty=$(printf '%s' "$allowed" | tr '|' ',')
        report "$file" "$line" "invalid ${key}: '${value}' (expected one of: ${pretty})"
    fi
}

# Lines (with continuation list items) belonging to a key's value block.
extract_field_block() {
    local file="$1" s="$2" e="$3" key="$4"
    awk -v s="$s" -v e="$e" -v k="^${key}:" '
        BEGIN{inblock=0}
        NR>=s && NR<=e {
            if ($0 ~ k) { print; inblock=1; next }
            if (inblock) {
                if ($0 ~ /^[[:space:]]+-/) { print; next }
                else { inblock=0 }
            }
        }
    ' "$file"
}

# All [[slug]] links inside a field's value block.
field_links() {
    local file="$1" s="$2" e="$3" key="$4"
    extract_field_block "$file" "$s" "$e" "$key" | grep -oE '\[\[[A-Za-z0-9_-]+\]\]' \
        | sed -E 's/^\[\[//; s/\]\]$//'
}

# All [[slug]] links anywhere in the whole file (frontmatter + body).
all_links_in_file() {
    local file="$1"
    grep -oE '\[\[[A-Za-z0-9_-]+\]\]' "$file" | sed -E 's/^\[\[//; s/\]\]$//' | sort -u
}

check_links_resolve() {
    # $1 file -> reports any [[slug]] link that doesn't resolve to people/<slug>.md
    local file="$1"
    local slug link_line
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        if ! grep -qxF "$slug" "$people_slugs_file"; then
            link_line=$(grep -nF "[[${slug}]]" "$file" | head -n1 | cut -d: -f1)
            [ -n "$link_line" ] || link_line=1
            report "$file" "$link_line" "broken link: [[${slug}]] does not resolve to people/${slug}.md"
        fi
    done <<EOF
$(all_links_in_file "$file")
EOF
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

if [ -d "$store_dir/people" ]; then
    for f in "$store_dir/people"/*.md; do
        [ -e "$f" ] || continue
        base=$(basename "$f" .md)
        printf '%s\n' "$base" >> "$people_slugs_file"
    done
fi

if [ -d "$store_dir/people" ]; then
    for f in "$store_dir/people"/*.md; do
        [ -e "$f" ] || continue
        files_checked=$((files_checked + 1))

        fm_end=$(find_frontmatter_end "$f")
        if [ -z "$fm_end" ]; then
            report "$f" 1 "malformed frontmatter: missing opening/closing ---"
            continue
        fi
        fm_start=2
        fm_body_end=$((fm_end - 1))
        check_frontmatter_lines_parseable "$f" "$fm_start" "$fm_body_end"

        require_field "$f" "$fm_start" "$fm_body_end" "schema_version" > /dev/null
        name_line=$(require_field "$f" "$fm_start" "$fm_body_end" "name")

        if [ -n "$name_line" ]; then
            name_val=$(scalar_value "$f" "$name_line" "name")
            slug=$(kebab "$name_val")
            printf '%s\t%s\n' "$slug" "$f" >> "$kebab_map_file"
        fi

        tier_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "tier")
        if [ -n "$tier_line" ]; then
            tier_val=$(scalar_value "$f" "$tier_line" "tier")
            check_enum "$f" "$tier_line" "tier" "$tier_val" "inner-circle|close|active|dormant"
        fi

        # Facts section: every bullet must carry a provenance tag.
        untagged=$(awk '
            /^## Facts$/{infacts=1; next}
            /^## /{infacts=0}
            infacts && /^- / { print NR":"$0 }
        ' "$f")
        if [ -n "$untagged" ]; then
            while IFS= read -r entry; do
                [ -n "$entry" ] || continue
                ln="${entry%%:*}"
                txt="${entry#*:}"
                if ! printf '%s' "$txt" | grep -qE '^- \*\*\[(told-by-user|inferred-public-web)\]\*\*'; then
                    report "$f" "$ln" "Facts bullet missing provenance tag ([told-by-user] or [inferred-public-web])"
                fi
            done <<EOF
$untagged
EOF
        fi

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
            name_line=$(find_field_line "$file" 2 "$(($(find_frontmatter_end "$file") - 1))" "name")
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
# Pass 2: interactions/
# ---------------------------------------------------------------------------

if [ -d "$store_dir/interactions" ]; then
    for f in "$store_dir/interactions"/*.md; do
        [ -e "$f" ] || continue
        files_checked=$((files_checked + 1))

        fm_end=$(find_frontmatter_end "$f")
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

        people_line=$(require_field "$f" "$fm_start" "$fm_body_end" "people")
        if [ -n "$people_line" ]; then
            people_links=$(field_links "$f" "$fm_start" "$fm_body_end" "people")
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

        fm_end=$(find_frontmatter_end "$f")
        if [ -z "$fm_end" ]; then
            report "$f" 1 "malformed frontmatter: missing opening/closing ---"
            continue
        fi
        fm_start=2
        fm_body_end=$((fm_end - 1))
        check_frontmatter_lines_parseable "$f" "$fm_start" "$fm_body_end"

        require_field "$f" "$fm_start" "$fm_body_end" "schema_version" > /dev/null
        require_field "$f" "$fm_start" "$fm_body_end" "id" > /dev/null
        require_field "$f" "$fm_start" "$fm_body_end" "due" > /dev/null
        require_field "$f" "$fm_start" "$fm_body_end" "why" > /dev/null

        people_line=$(require_field "$f" "$fm_start" "$fm_body_end" "people")
        if [ -n "$people_line" ]; then
            people_links=$(field_links "$f" "$fm_start" "$fm_body_end" "people")
            if [ -z "$people_links" ]; then
                report "$f" "$people_line" "wakeup has no people linked"
            fi
        fi

        status_line=$(require_field "$f" "$fm_start" "$fm_body_end" "status")
        status_val=""
        if [ -n "$status_line" ]; then
            status_val=$(scalar_value "$f" "$status_line" "status")
            check_enum "$f" "$status_line" "status" "$status_val" "pending|fired|snoozed|dismissed"
        fi

        origin_line=$(require_field "$f" "$fm_start" "$fm_body_end" "origin")
        origin_val=""
        if [ -n "$origin_line" ]; then
            origin_val=$(scalar_value "$f" "$origin_line" "origin")
            check_enum "$f" "$origin_line" "origin" "$origin_val" "user-ask|signal|standing"
        fi

        if [ "$origin_val" = "signal" ]; then
            src_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "source-signal")
            if [ -z "$src_line" ]; then
                report "$f" "$origin_line" "origin: signal requires a non-null source-signal"
            else
                src_val=$(scalar_value "$f" "$src_line" "source-signal")
                if [ -z "$src_val" ] || [ "$src_val" = "null" ]; then
                    report "$f" "$src_line" "origin: signal requires a non-null source-signal"
                fi
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

        fm_end=$(find_frontmatter_end "$f")
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

        person_line=$(require_field "$f" "$fm_start" "$fm_body_end" "person")
        if [ -n "$person_line" ]; then
            person_links=$(field_links "$f" "$fm_start" "$fm_body_end" "person")
            if [ -z "$person_links" ]; then
                report "$f" "$person_line" "signal event has no person linked"
            fi
        fi

        conf_line=$(require_field "$f" "$fm_start" "$fm_body_end" "confidence")
        if [ -n "$conf_line" ]; then
            conf_val=$(scalar_value "$f" "$conf_line" "confidence")
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
