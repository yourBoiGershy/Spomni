#!/usr/bin/env bash
# oss-guard.sh — read-only open-source readiness guard.
#
# Fails (exit 1) if the tracked tree in the current git repo leaks user data,
# personal paths/emails/phone numbers, secrets, symlinks that escape the
# packages/skills contract, outbound-send capability outside the
# draft-never-send invariant, or third-party enrichment/scraping references.
# Prints one "FAIL: <check>: <detail>" line per finding and "OK: oss-guard
# clean" when nothing is found.
#
# Usage:
#   bash .claude/scripts/oss-guard.sh              # run every check
#   bash .claude/scripts/oss-guard.sh --only NAME   # run a single check
#   bash .claude/scripts/oss-guard.sh --list        # list check names
#
# Run in CI via .github/workflows/ci.yml, and locally before opening a PR:
#   bash .claude/scripts/oss-guard.sh
#
# Read-only: never mutates the working tree or the index. bash 3.2 portable
# (no associative arrays used as arrays are fine in 3.2; no mapfile, no
# `readlink -f`, no `${var,,}` case folding).
#
# Every content-scanning check excludes the guard's own files (this script
# and .claude/scripts/tests/) via the SELF_EXCLUDE pathspec below — its
# source necessarily contains the literal strings it hunts for (e.g. the
# secrets pattern's own "sk-ant-" literal, and the test suite's synthetic-
# violation fixtures). This only bites once these files are *tracked*:
# `git grep` (no revision given) only scans tracked content, so an untracked
# working copy is invisible to it — don't mistake a locally-clean run for
# proof the exclusion works; verify against a repo where these files are
# actually committed (see the self-exclusion test in
# .claude/scripts/tests/run-oss-guard-tests.sh).
#
# Checks (see .claude/scripts/tests/run-oss-guard-tests.sh for the fixture
# that trips each one):
#   1. tracked-data        — data/ tracks nothing but data/README.md
#   2. tracked-symlinks     — no tracked symlinks, except a
#                             .claude/skills/<name> symlink whose target
#                             resolves under packages/*/skills/
#   3. personal-paths       — no /Users/<lowercase-name> paths (aside from
#                             /Users/example/, /Users/ericg,
#                             ~/Documents/relationship-agent)
#   4. personal-emails      — no email addresses outside the placeholder /
#                             vendor-notification domain allowlist (subdomains
#                             of an allowed base domain pass too, e.g.
#                             e.linkedin.com, group.calendar.google.com; any
#                             domain carrying "example" as a full label, e.g.
#                             example.co / brandsite.example.com, is a
#                             placeholder; localhost/*.local also pass)
#   5. phone-numbers        — no phone-number-shaped strings in fixtures /
#                             goldens / evals (ISO dates, hex hashes, bare
#                             digit runs with no separator/leading '+', and
#                             the reserved-fictional 555 range are excluded)
#   6. secrets              — no API keys / tokens / private key blocks
#   7. never-send           — no outbound-send tool calls outside tests/
#                             evals/, except SKILL.md docs that state the
#                             draft-never-send invariant
#   8. no-enrichment        — no third-party people-enrichment/scraping host
#                             references under packages/
#   9. gitignore-baseline   — .gitignore carries the required ignore lines
#
# Exit code: 0 clean, 1 findings, 2 usage error.

set -u

# Operates on the git repo containing the *caller's* working directory (not
# this script's own location) so it can be pointed at any checkout — the
# real one, or a scratch repo built by the test suite.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
    printf 'oss-guard.sh: not inside a git repository\n' >&2
    exit 2
fi
cd "$REPO_ROOT" || exit 2

# The guard's own source necessarily contains the literal strings it hunts
# for (secret-pattern definitions, and the test suite's synthetic-violation
# fixtures printf'd inline) — exclude its own files from every git-grep-based
# check so it doesn't trip on itself once tracked.
SELF_EXCLUDE=(':!.claude/scripts/oss-guard.sh' ':!.claude/scripts/tests/')

FINDINGS=0

report() {
    # $1 = check name, $2 = detail
    printf 'FAIL: %s: %s\n' "$1" "$2"
    FINDINGS=$((FINDINGS + 1))
}

# --- pure-bash relative path normalizer (collapses "." and "..") ---
normalize_path() {
    local input="$1"
    local IFS='/'
    local -a parts
    parts=($input)
    local -a stack
    stack=()
    local part
    for part in "${parts[@]}"; do
        case "$part" in
            ''|'.') continue ;;
            '..')
                if [ "${#stack[@]}" -gt 0 ]; then
                    unset 'stack[${#stack[@]}-1]'
                fi
                ;;
            *) stack+=("$part") ;;
        esac
    done
    local result=""
    for part in "${stack[@]}"; do
        result="$result/$part"
    done
    printf '%s' "${result#/}"
}

# ---------------------------------------------------------------------------
check_tracked_data() {
    local files
    files="$(git ls-files data/ 2>/dev/null)"
    [ -z "$files" ] && return 0
    local f
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if [ "$f" != "data/README.md" ]; then
            report "tracked-data" "$f is tracked (data/ must contain only data/README.md)"
        fi
    done <<EOF
$files
EOF
}

# ---------------------------------------------------------------------------
check_tracked_symlinks() {
    # working-tree state: a tracked path is only a symlink-finding if the
    # on-disk entry is actually a symlink right now (not the index/HEAD blob
    # type) — contributors run this pre-commit, CI runs it on a checkout.
    local path target dirpath resolved
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        [ -L "$path" ] || continue

        # allowed shape: a direct child of .claude/skills/, whose target
        # (as it exists on disk) resolves under packages/*/skills/<name> or
        # packages/*/*/skills/<name> (connectors keep skills one level
        # deeper, e.g. packages/connectors/calendar-in/skills/calendar-sweep)
        if printf '%s' "$path" | grep -qE '^\.claude/skills/[^/]+$'; then
            target="$(readlink "$path" 2>/dev/null)"
            dirpath="$(dirname "$path")"
            resolved="$(normalize_path "$dirpath/$target")"
            if printf '%s' "$resolved" | grep -qE '^packages/[^/]+/skills/.+'; then
                continue
            fi
            if printf '%s' "$resolved" | grep -qE '^packages/[^/]+/[^/]+/skills/.+'; then
                continue
            fi
        fi
        report "tracked-symlinks" "$path is a tracked symlink"
    done < <(git ls-files 2>/dev/null)
}

# ---------------------------------------------------------------------------
check_personal_paths() {
    local matches
    matches="$(git grep -n -I -E '/Users/[a-z]' -- . "${SELF_EXCLUDE[@]}" 2>/dev/null)"
    [ -z "$matches" ] && return 0
    local line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
            *"/Users/example/"*) continue ;;
            *"/Users/ericg"*) continue ;;
            *"~/Documents/relationship-agent"*) continue ;;
        esac
        report "personal-paths" "$line"
    done <<EOF
$matches
EOF
}

# ---------------------------------------------------------------------------
# is $1 equal to, or a subdomain of, base domain $2?
is_domain_or_subdomain() {
    local d="$1" base="$2"
    [ "$d" = "$base" ] && return 0
    case "$d" in
        *".$base") return 0 ;;
    esac
    return 1
}

domain_allowed() {
    # $1 = domain (already lowercased)
    local d="$1"
    local base

    # placeholder base domains, and any of their subdomains
    for base in example.com example.org example.net example.co localhost; do
        is_domain_or_subdomain "$d" "$base" && return 0
    done

    # bare placeholder TLD-style suffixes, and *.local for local-only mail
    case "$d" in
        *.local) return 0 ;;
        test|*.test) return 0 ;;
        invalid|*.invalid) return 0 ;;
    esac

    # fixture convention: any domain carrying "example" as a full label
    # anywhere (example.co, brandsite.example.com, example.net, ...)
    case ".$d." in
        *".example."*) return 0 ;;
    esac

    # vendor allowlist (notification/system senders), and their subdomains
    for base in linkedin.com beeper.com github.com composio.dev anthropic.com google.com; do
        is_domain_or_subdomain "$d" "$base" && return 0
    done

    return 1
}

check_personal_emails() {
    local matches
    matches="$(git grep -n -I -E '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
        -- 'packages/**' 'docs/**' '*.md' "${SELF_EXCLUDE[@]}" 2>/dev/null)"
    [ -z "$matches" ] && return 0
    local line email domain lower
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # a line can have multiple emails; check every one
        for email in $(printf '%s' "$line" | grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'); do
            domain="${email#*@}"
            lower="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')"
            if ! domain_allowed "$lower"; then
                report "personal-emails" "$line"
                break
            fi
        done
    done <<EOF
$matches
EOF
}

# ---------------------------------------------------------------------------
# does phone-shaped match $1 have at least one separator, or a leading '+'?
phone_match_has_separator() {
    local m="$1"
    case "$m" in
        '+'*) return 0 ;;
    esac
    printf '%s' "$m" | grep -qE '[-() .]'
}

# is phone-shaped match $1 in the reserved-fictional 555 range — i.e. does
# "555" sit immediately after an optional leading '1' country code?
phone_match_is_reserved_555() {
    local m="$1" digits stripped
    digits="$(printf '%s' "$m" | tr -cd '0-9')"
    stripped="$digits"
    case "$digits" in
        1*) stripped="${digits#1}" ;;
    esac
    printf '%s' "$stripped" | grep -qE '^555'
}

check_phone_numbers() {
    local matches
    matches="$(git grep -n -I -E '\+?[0-9][0-9 ()-]{8,}[0-9]' \
        -- 'packages/**/fixtures/**' 'packages/**/goldens/**' 'packages/**/evals/**' "${SELF_EXCLUDE[@]}" 2>/dev/null)"
    [ -z "$matches" ] && return 0
    local line content m keep
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        content="${line#*:*:}"
        # skip ISO timestamps / dates
        if printf '%s' "$content" | grep -qE 'T[0-9]{2}:'; then
            continue
        fi
        if printf '%s' "$content" | grep -qE '[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
            continue
        fi
        # skip lines whose only digit run sits inside a 32+ hex-char token
        if printf '%s' "$content" | grep -qE '[0-9a-fA-F]{32,}'; then
            continue
        fi

        keep=0
        while IFS= read -r m; do
            [ -z "$m" ] && continue
            phone_match_has_separator "$m" || continue
            phone_match_is_reserved_555 "$m" && continue
            keep=1
        done < <(printf '%s\n' "$content" | grep -oE '\+?[0-9][0-9 ()-]{8,}[0-9]')

        [ "$keep" -eq 1 ] && report "phone-numbers" "$line"
    done <<EOF
$matches
EOF
}

# ---------------------------------------------------------------------------
check_secrets() {
    local matches
    matches="$(git grep -n -I -E 'sk-ant-|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|xox[bapr]-|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----' \
        -- . "${SELF_EXCLUDE[@]}" 2>/dev/null)"
    [ -z "$matches" ] && return 0
    local line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        report "secrets" "$line"
    done <<EOF
$matches
EOF
}

# ---------------------------------------------------------------------------
check_never_send() {
    local pattern='send_message|send_email|gmail__send|slack_send_message|mcp__beeper__send_message|messages\.send|chat\.postMessage|(-X *)?POST[^\n]*/v1/chats/[^ ]*/(messages|reminders)|/v1/chats/[^ ]*/(messages|reminders)[^\n]*(-X *)?POST'
    local matches
    matches="$(git grep -n -I -E "$pattern" \
        -- 'packages/connectors/**' 'packages/attention/**' "${SELF_EXCLUDE[@]}" 2>/dev/null)"
    [ -z "$matches" ] && return 0
    local line path
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        path="${line%%:*}"

        # exclude tests/ and evals/ trees
        case "$path" in
            */tests/*|*/evals/*) continue ;;
        esac

        case "$path" in
            packages/connectors/beeper-out/scripts/*)
                if grep -qF 'refuse: chat id not in profile ## Notify' "$path" 2>/dev/null; then
                    continue
                fi
                report "never-send (beeper-out without self-only guard)" "$line"
                continue
                ;;
        esac

        case "$path" in
            */SKILL.md)
                if grep -qiE 'draft, never send|human sends' "$path" 2>/dev/null; then
                    continue
                fi
                ;;
            *.md)
                # non-SKILL.md markdown is excluded from this check
                continue
                ;;
        esac

        report "never-send" "$line"
    done <<EOF
$matches
EOF
}

# ---------------------------------------------------------------------------
check_no_enrichment() {
    local pattern='clearbit|apollo\.io|hunter\.io|rocketreach|zoominfo|peopledatalabs|fullcontact|pipl\.com|linkedin\.com/in/'
    local matches
    matches="$(git grep -n -I -E "$pattern" -- 'packages/**' "${SELF_EXCLUDE[@]}" 2>/dev/null)"
    [ -z "$matches" ] && return 0
    local line path
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        path="${line%%:*}"

        # linkedin.com/in/ is scoped out of fixtures anywhere (beeper-in /
        # gmail-in legitimately carry LinkedIn notification emails there)
        if printf '%s' "$line" | grep -qE 'linkedin\.com/in/' && ! printf '%s' "$line" | grep -qE 'clearbit|apollo\.io|hunter\.io|rocketreach|zoominfo|peopledatalabs|fullcontact|pipl\.com'; then
            case "$path" in
                */fixtures/*) continue ;;
            esac
        fi

        report "no-enrichment" "$line"
    done <<EOF
$matches
EOF
}

# ---------------------------------------------------------------------------
check_gitignore_baseline() {
    local gi="$REPO_ROOT/.gitignore"
    if [ ! -f "$gi" ]; then
        report "gitignore-baseline" ".gitignore is missing"
        return 0
    fi
    local required
    for required in 'data/*' '!data/README.md' '.env' '.env.*' 'node_modules/' '.claude/settings.local.json'; do
        if ! grep -qxF "$required" "$gi"; then
            report "gitignore-baseline" ".gitignore is missing required line: $required"
        fi
    done
}

# ---------------------------------------------------------------------------
CHECK_NAMES="tracked-data tracked-symlinks personal-paths personal-emails phone-numbers secrets never-send no-enrichment gitignore-baseline"

run_check() {
    case "$1" in
        tracked-data) check_tracked_data ;;
        tracked-symlinks) check_tracked_symlinks ;;
        personal-paths) check_personal_paths ;;
        personal-emails) check_personal_emails ;;
        phone-numbers) check_phone_numbers ;;
        secrets) check_secrets ;;
        never-send) check_never_send ;;
        no-enrichment) check_no_enrichment ;;
        gitignore-baseline) check_gitignore_baseline ;;
        *)
            printf 'unknown check: %s\n' "$1" >&2
            printf 'known checks: %s\n' "$CHECK_NAMES" >&2
            exit 2
            ;;
    esac
}

ONLY=""
case "${1:-}" in
    --list)
        for c in $CHECK_NAMES; do printf '%s\n' "$c"; done
        exit 0
        ;;
    --only)
        ONLY="${2:-}"
        if [ -z "$ONLY" ]; then
            printf -- '--only requires a check name\n' >&2
            exit 2
        fi
        ;;
    "") : ;;
    *)
        printf 'usage: %s [--list | --only NAME]\n' "$0" >&2
        exit 2
        ;;
esac

if [ -n "$ONLY" ]; then
    run_check "$ONLY"
else
    for c in $CHECK_NAMES; do
        run_check "$c"
    done
fi

if [ "$FINDINGS" -eq 0 ]; then
    printf 'OK: oss-guard clean\n'
    exit 0
else
    exit 1
fi
