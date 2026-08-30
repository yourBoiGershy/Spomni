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

# Lines belonging to a mapping-valued key's block (indented "subkey: value"
# lines), including the key line itself. E.g. for `proposed-event:` followed
# by indented `title:`/`start:`/... lines.
extract_mapping_block() {
    local file="$1" s="$2" e="$3" key="$4"
    awk -v s="$s" -v e="$e" -v k="^${key}:" '
        BEGIN{inblock=0}
        NR>=s && NR<=e {
            if ($0 ~ k) { print; inblock=1; next }
            if (inblock) {
                if ($0 ~ /^[[:space:]]+[A-Za-z0-9_-]+:/) { print; next }
                else { inblock=0 }
            }
        }
    ' "$file"
}

# Prints the line number of an indented "subkey:" line inside a mapping
# key's block, or nothing.
find_mapping_field_line() {
    local file="$1" s="$2" e="$3" mapkey="$4" subkey="$5"
    awk -v s="$s" -v e="$e" -v mk="^${mapkey}:" -v sk="^[[:space:]]+${subkey}:" '
        BEGIN{inblock=0}
        NR>=s && NR<=e {
            if ($0 ~ mk) { inblock=1; next }
            if (inblock) {
                if ($0 ~ /^[[:space:]]+[A-Za-z0-9_-]+:/) {
                    if ($0 ~ sk) { print NR; exit }
                    next
                } else { inblock=0 }
            }
        }
    ' "$file"
}

# Scalar value of an indented "  key: value" mapping-block line, quotes
# stripped.
mapping_scalar_value() {
    local file="$1" line="$2" key="$3"
    sed -n "${line}p" "$file" \
        | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//" \
        | sed -E 's/[[:space:]]+$//' \
        | sed -E 's/^"(.*)"$/\1/'
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

        person_sv_line=$(require_field "$f" "$fm_start" "$fm_body_end" "schema_version")
        if [ -n "$person_sv_line" ]; then
            person_sv_val=$(scalar_value "$f" "$person_sv_line" "schema_version")
            check_enum "$f" "$person_sv_line" "schema_version" "$person_sv_val" "1\.0\.0|1\.1\.0|1\.2\.0|1\.3\.0"
        fi
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

        # --- person.md 1.2.0 tier_source (optional, plan 31 D4) ---
        tier_source_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "tier_source")
        if [ -n "$tier_source_line" ]; then
            if [ -z "$tier_line" ]; then
                report "$f" "$tier_source_line" "tier_source is set without tier"
            else
                tier_source_val=$(scalar_value "$f" "$tier_source_line" "tier_source")
                check_enum "$f" "$tier_source_line" "tier_source" "$tier_source_val" "derived|stated-by-user"
            fi
        fi

        # --- person.md 1.1.0 kind fields (optional, plan 30) ---
        kind_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "kind")
        kind_note_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "kind_note")
        kind_source_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "kind_source")
        kind_expires_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "kind_expires")
        kind_updated_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "kind_updated")

        if [ -n "$kind_line" ]; then
            kind_val=$(scalar_value "$f" "$kind_line" "kind")
            check_enum "$f" "$kind_line" "kind" "$kind_val" "friend|family|collaborator|professional|community|scheduling|transactional|unsolicited|unknown"

            if [ -z "$kind_note_line" ]; then
                report "$f" "$kind_line" "kind is set but missing required field: kind_note"
            else
                kind_note_val=$(scalar_value "$f" "$kind_note_line" "kind_note")
                [ -n "$kind_note_val" ] || report "$f" "$kind_note_line" "kind_note must not be empty"
            fi

            if [ -z "$kind_source_line" ]; then
                report "$f" "$kind_line" "kind is set but missing required field: kind_source"
            else
                kind_source_val=$(scalar_value "$f" "$kind_source_line" "kind_source")
                check_enum "$f" "$kind_source_line" "kind_source" "$kind_source_val" "stated-by-user|derived"
            fi

            if [ -z "$kind_updated_line" ]; then
                report "$f" "$kind_line" "kind is set but missing required field: kind_updated"
            else
                kind_updated_val=$(scalar_value "$f" "$kind_updated_line" "kind_updated")
                if [ -z "$kind_updated_val" ] || ! printf '%s' "$kind_updated_val" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
                    report "$f" "$kind_updated_line" "invalid kind_updated: '${kind_updated_val}' (expected ISO 8601 date YYYY-MM-DD)"
                fi
            fi

            if [ -n "$kind_expires_line" ]; then
                kind_expires_val=$(scalar_value "$f" "$kind_expires_line" "kind_expires")
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
                if ! printf '%s' "$txt" | grep -qE '^- \*\*\[(told-by-user|inferred-public-web|inferred-from-thread)\]\*\*'; then
                    report "$f" "$ln" "Facts bullet missing provenance tag ([told-by-user], [inferred-public-web], or [inferred-from-thread])"
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
# Pass 1.5: profile.md (singleton, optional — absence is not an error)
# ---------------------------------------------------------------------------

if [ -f "$store_dir/profile.md" ]; then
    f="$store_dir/profile.md"
    files_checked=$((files_checked + 1))

    fm_end=$(find_frontmatter_end "$f")
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

    fm_end=$(find_frontmatter_end "$f")
    if [ -z "$fm_end" ]; then
        report "$f" 1 "malformed frontmatter: missing opening/closing ---"
    else
        fm_start=2
        fm_body_end=$((fm_end - 1))
        check_frontmatter_lines_parseable "$f" "$fm_start" "$fm_body_end"

        require_field "$f" "$fm_start" "$fm_body_end" "schema_version" > /dev/null

        status_line=$(require_field "$f" "$fm_start" "$fm_body_end" "status")
        status_val=""
        if [ -n "$status_line" ]; then
            status_val=$(scalar_value "$f" "$status_line" "status")
            check_enum "$f" "$status_line" "status" "$status_val" "draft|provisional|confirmed"
        fi

        provenance_line=$(require_field "$f" "$fm_start" "$fm_body_end" "provenance")
        provenance_val=""
        if [ -n "$provenance_line" ]; then
            provenance_val=$(scalar_value "$f" "$provenance_line" "provenance")
            check_enum "$f" "$provenance_line" "provenance" "$provenance_val" "observed-from-behavior|stated-by-user"
        fi

        confirmed_at_line=$(require_field "$f" "$fm_start" "$fm_body_end" "confirmed_at")
        confirmed_at_val=""
        if [ -n "$confirmed_at_line" ]; then
            confirmed_at_val=$(scalar_value "$f" "$confirmed_at_line" "confirmed_at")
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

        revision_line=$(require_field "$f" "$fm_start" "$fm_body_end" "revision")
        if [ -n "$revision_line" ]; then
            revision_val=$(scalar_value "$f" "$revision_line" "revision")
            if ! printf '%s' "$revision_val" | grep -qE '^[0-9]+$'; then
                report "$f" "$revision_line" "invalid revision: '${revision_val}' (expected non-negative integer)"
            fi
        fi

        derived_at_line=$(require_field "$f" "$fm_start" "$fm_body_end" "derived_at")
        if [ -n "$derived_at_line" ]; then
            derived_at_val=$(scalar_value "$f" "$derived_at_line" "derived_at")
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

        sv_line=$(require_field "$f" "$fm_start" "$fm_body_end" "schema_version")
        sv_val=""
        if [ -n "$sv_line" ]; then
            sv_val=$(scalar_value "$f" "$sv_line" "schema_version")
            check_enum "$f" "$sv_line" "schema_version" "$sv_val" "1\.0\.0|1\.1\.0|1\.2\.0"
        fi
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

        # --- schema_version 1.1.0 fields (validated only when present) ---
        fired_on_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "fired-on")
        if [ -n "$fired_on_line" ]; then
            fired_on_val=$(scalar_value "$f" "$fired_on_line" "fired-on")
            if [ -n "$fired_on_val" ] && [ "$fired_on_val" != "null" ]; then
                if ! printf '%s' "$fired_on_val" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
                    report "$f" "$fired_on_line" "invalid fired-on: '${fired_on_val}' (expected ISO 8601 date YYYY-MM-DD)"
                fi
            fi
        fi

        dismiss_reason_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "dismiss-reason")
        dismiss_reason_val=""
        if [ -n "$dismiss_reason_line" ]; then
            dismiss_reason_val=$(scalar_value "$f" "$dismiss_reason_line" "dismiss-reason")
            if [ -n "$dismiss_reason_val" ] && [ "$dismiss_reason_val" != "null" ]; then
                check_enum "$f" "$dismiss_reason_line" "dismiss-reason" "$dismiss_reason_val" "not-now|not-this-person|not-this-signal-type|already-handled"
            fi
        fi

        acted_on_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "acted-on")
        if [ -n "$acted_on_line" ]; then
            acted_on_val=$(scalar_value "$f" "$acted_on_line" "acted-on")
            if [ -n "$acted_on_val" ] && [ "$acted_on_val" != "null" ]; then
                check_enum "$f" "$acted_on_line" "acted-on" "$acted_on_val" "true|false"
            fi
        fi

        snooze_count_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "snooze-count")
        if [ -n "$snooze_count_line" ]; then
            snooze_count_val=$(scalar_value "$f" "$snooze_count_line" "snooze-count")
            if [ -n "$snooze_count_val" ] && [ "$snooze_count_val" != "null" ]; then
                if ! printf '%s' "$snooze_count_val" | grep -qE '^[0-9]+$'; then
                    report "$f" "$snooze_count_line" "invalid snooze-count: '${snooze_count_val}' (expected non-negative integer)"
                fi
            fi
        fi

        signal_type_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "signal-type")
        if [ -n "$signal_type_line" ]; then
            signal_type_val=$(scalar_value "$f" "$signal_type_line" "signal-type")
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
        kind_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "kind")
        kind_val=""
        if [ -n "$kind_line" ]; then
            kind_val=$(scalar_value "$f" "$kind_line" "kind")
            if [ -n "$kind_val" ] && [ "$kind_val" != "null" ]; then
                check_enum "$f" "$kind_line" "kind" "$kind_val" "nudge|event-proposal"
            fi
        fi

        proposed_event_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "proposed-event")
        pe_present=0
        if [ -n "$proposed_event_line" ]; then
            pe_val=$(scalar_value "$f" "$proposed_event_line" "proposed-event")
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

        confirmed_on_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "confirmed-on")
        confirmed_on_val=""
        if [ -n "$confirmed_on_line" ]; then
            confirmed_on_val=$(scalar_value "$f" "$confirmed_on_line" "confirmed-on")
            if [ -n "$confirmed_on_val" ] && [ "$confirmed_on_val" != "null" ]; then
                if ! printf '%s' "$confirmed_on_val" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
                    report "$f" "$confirmed_on_line" "invalid confirmed-on: '${confirmed_on_val}' (expected ISO 8601 date YYYY-MM-DD)"
                fi
            fi
        fi

        created_event_id_line=$(find_field_line "$f" "$fm_start" "$fm_body_end" "created-event-id")
        created_event_id_val=""
        if [ -n "$created_event_id_line" ]; then
            created_event_id_val=$(scalar_value "$f" "$created_event_id_line" "created-event-id")
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
