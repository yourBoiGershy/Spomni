#!/usr/bin/env bash
# .claude/scripts/tests/run-oss-guard-tests.sh
#
# Asserts that .claude/scripts/oss-guard.sh trips (exit 1, one "FAIL: <name>:"
# line) on exactly the finding it's built to catch, and stays clean (exit 0,
# "OK: oss-guard clean") on fixtures that don't trip it — including the
# .claude/skills/<name> -> packages/*/skills/... symlink carve-out.
#
# Builds a scratch git repo per assertion group under `mktemp -d` (with a
# GNU/BSD fallback) so the real repo under test is never touched, commits a
# minimal fixture that trips (or doesn't trip) one check, and runs
# oss-guard.sh --only <check> against it.
#
# bash 3.2 portable (no associative arrays, no mapfile) — must run under
# macOS's stock /bin/bash, invocable from anywhere.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
GUARD="$REPO_ROOT/.claude/scripts/oss-guard.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

if [ ! -x "$GUARD" ]; then
    echo "SKIP: $GUARD not found or not executable"
    echo ""
    echo "SUMMARY: 0 passed, 0 failed, guard missing"
    exit 1
fi

mk_tmp_dir() {
    mktemp -d 2>/dev/null || mktemp -d -t oss-guard-test
}

# --- build a fresh, minimal-clean scratch git repo; echoes its path ---
new_repo() {
    local dir
    dir="$(mk_tmp_dir)"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"

    mkdir -p "$dir/data" "$dir/packages/connectors/gmail-in" "$dir/packages/attention"
    printf '# data\n\nUser data lives outside this repo.\n' > "$dir/data/README.md"
    cat > "$dir/.gitignore" <<'GI'
data/*
!data/README.md
.env
.env.*
node_modules/
.claude/settings.local.json
GI
    printf 'no personal data here\n' > "$dir/packages/connectors/gmail-in/README.md"

    (cd "$dir" && git add -A && git commit -q -m "clean baseline")
    printf '%s' "$dir"
}

# --- run the guard against a repo, capturing output+status ---
run_guard() {
    # $1 = repo dir, $2 = --only check (optional)
    local dir="$1"
    local only="${2:-}"
    if [ -n "$only" ]; then
        (cd "$dir" && bash "$GUARD" --only "$only")
    else
        (cd "$dir" && bash "$GUARD")
    fi
}

commit_extra() {
    # $1 = repo dir, $2... = git add args already written to disk
    (cd "$1" && git add -A && git commit -q -m "fixture")
}

# ===========================================================================
# 0. clean baseline: full run passes
# ===========================================================================
REPO="$(new_repo)"
out="$(run_guard "$REPO")"
status=$?
if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -q '^OK: oss-guard clean$'; then
    pass "clean baseline: full run exits 0 with OK line"
else
    fail "clean baseline: full run expected exit 0 + OK line, got status=$status output=$out"
fi
rm -rf "$REPO"

# ===========================================================================
# 1. tracked-data
# ===========================================================================
REPO="$(new_repo)"
mkdir -p "$REPO/data/people"
printf 'name: Jane Doe\n' > "$REPO/data/people/jane-doe.md"
(cd "$REPO" && git add -f data/people/jane-doe.md && git commit -q -m "fixture")
out="$(run_guard "$REPO" tracked-data)"
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL: tracked-data:'; then
    pass "tracked-data: fails when data/ tracks more than README.md"
else
    fail "tracked-data: expected FAIL, got status=$status output=$out"
fi
rm -rf "$REPO"

REPO="$(new_repo)"
out="$(run_guard "$REPO" tracked-data)"
status=$?
if [ "$status" -eq 0 ] && ! printf '%s' "$out" | grep -q 'FAIL:'; then
    pass "tracked-data: passes on clean baseline"
else
    fail "tracked-data: expected pass on baseline, got status=$status output=$out"
fi
rm -rf "$REPO"

# ===========================================================================
# 2. tracked-symlinks
# ===========================================================================
REPO="$(new_repo)"
(cd "$REPO" && ln -s /etc/passwd sneaky-link)
commit_extra "$REPO"
out="$(run_guard "$REPO" tracked-symlinks)"
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL: tracked-symlinks:'; then
    pass "tracked-symlinks: fails on a disallowed tracked symlink"
else
    fail "tracked-symlinks: expected FAIL, got status=$status output=$out"
fi
rm -rf "$REPO"

REPO="$(new_repo)"
mkdir -p "$REPO/.claude/skills"
(cd "$REPO/.claude/skills" && ln -s ../../packages/ingestion/skills/debrief debrief)
commit_extra "$REPO"
out="$(run_guard "$REPO" tracked-symlinks)"
status=$?
if [ "$status" -eq 0 ] && ! printf '%s' "$out" | grep -q 'FAIL:'; then
    pass "tracked-symlinks: allows .claude/skills/<name> -> packages/*/skills/..."
else
    fail "tracked-symlinks: expected pass on allowed skill symlink, got status=$status output=$out"
fi
rm -rf "$REPO"

REPO="$(new_repo)"
mkdir -p "$REPO/.claude/skills"
(cd "$REPO/.claude/skills" && ln -s ../../data/secrets bad-target)
commit_extra "$REPO"
out="$(run_guard "$REPO" tracked-symlinks)"
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL: tracked-symlinks:'; then
    pass "tracked-symlinks: rejects .claude/skills/<name> pointing outside packages/*/skills/"
else
    fail "tracked-symlinks: expected FAIL for off-target skill symlink, got status=$status output=$out"
fi
rm -rf "$REPO"

REPO="$(new_repo)"
mkdir -p "$REPO/.claude/skills"
(cd "$REPO/.claude/skills" && ln -s ../../packages/connectors/calendar-in/skills/calendar-sweep calendar-sweep)
commit_extra "$REPO"
out="$(run_guard "$REPO" tracked-symlinks)"
status=$?
if [ "$status" -eq 0 ] && ! printf '%s' "$out" | grep -q 'FAIL:'; then
    pass "tracked-symlinks: allows the connectors-deeper packages/*/*/skills/... shape"
else
    fail "tracked-symlinks: expected pass on connectors-deeper skill symlink, got status=$status output=$out"
fi
rm -rf "$REPO"

# ===========================================================================
# 3. personal-paths
# ===========================================================================
REPO="$(new_repo)"
printf 'export DATA_DIR=/Users/janedoe/relationship-agent-data\n' > "$REPO/setup-notes.md"
commit_extra "$REPO"
out="$(run_guard "$REPO" personal-paths)"
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL: personal-paths:'; then
    pass "personal-paths: fails on a leaked /Users/<name> path"
else
    fail "personal-paths: expected FAIL, got status=$status output=$out"
fi
rm -rf "$REPO"

REPO="$(new_repo)"
printf 'placeholder: /Users/example/relationship-agent-data\nallowed: /Users/ericg/Documents\n' > "$REPO/setup-notes.md"
commit_extra "$REPO"
out="$(run_guard "$REPO" personal-paths)"
status=$?
if [ "$status" -eq 0 ] && ! printf '%s' "$out" | grep -q 'FAIL:'; then
    pass "personal-paths: allows /Users/example/ and /Users/ericg"
else
    fail "personal-paths: expected pass, got status=$status output=$out"
fi
rm -rf "$REPO"

# ===========================================================================
# 4. personal-emails
# ===========================================================================
REPO="$(new_repo)"
mkdir -p "$REPO/docs"
printf 'contact: realuser123@gmail.com\n' > "$REPO/docs/notes.md"
commit_extra "$REPO"
out="$(run_guard "$REPO" personal-emails)"
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL: personal-emails:'; then
    pass "personal-emails: fails on a non-allowlisted email domain"
else
    fail "personal-emails: expected FAIL, got status=$status output=$out"
fi
rm -rf "$REPO"

REPO="$(new_repo)"
mkdir -p "$REPO/docs"
printf 'contact: alice@example.com and notice@linkedin.com\n' > "$REPO/docs/notes.md"
commit_extra "$REPO"
out="$(run_guard "$REPO" personal-emails)"
status=$?
if [ "$status" -eq 0 ] && ! printf '%s' "$out" | grep -q 'FAIL:'; then
    pass "personal-emails: allows placeholder and vendor-notification domains"
else
    fail "personal-emails: expected pass, got status=$status output=$out"
fi
rm -rf "$REPO"

REPO="$(new_repo)"
mkdir -p "$REPO/docs"
printf 'contact: dana@e.linkedin.com\nid: sched@group.calendar.google.com\nplaceholder: alex@example.co\nnews: hi@brandsite.example.com\n' \
    > "$REPO/docs/notes.md"
commit_extra "$REPO"
out="$(run_guard "$REPO" personal-emails)"
status=$?
if [ "$status" -eq 0 ] && ! printf '%s' "$out" | grep -q 'FAIL:'; then
    pass "personal-emails: allows vendor subdomains and the example.* placeholder family"
else
    fail "personal-emails: expected pass, got status=$status output=$out"
fi
rm -rf "$REPO"

# ===========================================================================
# 5. phone-numbers
# ===========================================================================
REPO="$(new_repo)"
mkdir -p "$REPO/packages/ingestion/tests/fixtures"
printf 'phone: +1 415-555-0134\n' > "$REPO/packages/ingestion/tests/fixtures/person.md"
commit_extra "$REPO"
out="$(run_guard "$REPO" phone-numbers)"
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL: phone-numbers:'; then
    pass "phone-numbers: fails on a phone-shaped string in fixtures/"
else
    fail "phone-numbers: expected FAIL, got status=$status output=$out"
fi
rm -rf "$REPO"

REPO="$(new_repo)"
mkdir -p "$REPO/packages/ingestion/tests/fixtures"
printf 'created: 2026-08-19T10:30:00-07:00\nhash: 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a1\n' \
    > "$REPO/packages/ingestion/tests/fixtures/person.md"
commit_extra "$REPO"
out="$(run_guard "$REPO" phone-numbers)"
status=$?
if [ "$status" -eq 0 ] && ! printf '%s' "$out" | grep -q 'FAIL:'; then
    pass "phone-numbers: ISO timestamps and hex hashes are excluded"
else
    fail "phone-numbers: expected pass, got status=$status output=$out"
fi
rm -rf "$REPO"

REPO="$(new_repo)"
mkdir -p "$REPO/packages/ingestion/tests/fixtures"
printf 'internalDate: "1788015000000"\nsortKey: "0000000101"\ntoken: "09612572260890495170"\n' \
    > "$REPO/packages/ingestion/tests/fixtures/person.md"
commit_extra "$REPO"
out="$(run_guard "$REPO" phone-numbers)"
status=$?
if [ "$status" -eq 0 ] && ! printf '%s' "$out" | grep -q 'FAIL:'; then
    pass "phone-numbers: pure digit runs with no separator/leading + never match"
else
    fail "phone-numbers: expected pass, got status=$status output=$out"
fi
rm -rf "$REPO"

REPO="$(new_repo)"
mkdir -p "$REPO/packages/ingestion/tests/fixtures"
printf 'a: "+1-555-0101"\nb: "+15551234567"\nc: "(555) 010-1234"\n' \
    > "$REPO/packages/ingestion/tests/fixtures/person.md"
commit_extra "$REPO"
out="$(run_guard "$REPO" phone-numbers)"
status=$?
if [ "$status" -eq 0 ] && ! printf '%s' "$out" | grep -q 'FAIL:'; then
    pass "phone-numbers: the reserved-fictional 555 range is excluded"
else
    fail "phone-numbers: expected pass, got status=$status output=$out"
fi
rm -rf "$REPO"

REPO="$(new_repo)"
mkdir -p "$REPO/packages/ingestion/tests/fixtures"
printf 'uk: +44 20 7946 0958\nus: (415) 867-5309\n' \
    > "$REPO/packages/ingestion/tests/fixtures/person.md"
commit_extra "$REPO"
out="$(run_guard "$REPO" phone-numbers)"
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -c 'FAIL: phone-numbers:' | grep -q '^2$'; then
    pass "phone-numbers: real non-555 numbers with separators still fail"
else
    fail "phone-numbers: expected 2 FAILs, got status=$status output=$out"
fi
rm -rf "$REPO"

# ===========================================================================
# 6. secrets
# ===========================================================================
REPO="$(new_repo)"
printf 'ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789\n' > "$REPO/notes.txt"
commit_extra "$REPO"
out="$(run_guard "$REPO" secrets)"
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL: secrets:'; then
    pass "secrets: fails on a leaked API key"
else
    fail "secrets: expected FAIL, got status=$status output=$out"
fi
rm -rf "$REPO"

# ===========================================================================
# 7. never-send
# ===========================================================================
REPO="$(new_repo)"
mkdir -p "$REPO/packages/connectors/gmail-out"
printf '#!/usr/bin/env bash\ngmail__send --to "$1"\n' > "$REPO/packages/connectors/gmail-out/deliver.sh"
commit_extra "$REPO"
out="$(run_guard "$REPO" never-send)"
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL: never-send:'; then
    pass "never-send: fails on an outbound send call outside tests/evals"
else
    fail "never-send: expected FAIL, got status=$status output=$out"
fi
rm -rf "$REPO"

REPO="$(new_repo)"
mkdir -p "$REPO/packages/connectors/gmail-out/skills"
cat > "$REPO/packages/connectors/gmail-out/skills/SKILL.md" <<'SKILL'
# Draft outreach

Uses gmail__send only after a human approves — draft, never send is the rule.
SKILL
commit_extra "$REPO"
out="$(run_guard "$REPO" never-send)"
status=$?
if [ "$status" -eq 0 ] && ! printf '%s' "$out" | grep -q 'FAIL:'; then
    pass "never-send: allows a SKILL.md that states the draft-never-send invariant"
else
    fail "never-send: expected pass, got status=$status output=$out"
fi
rm -rf "$REPO"

REPO="$(new_repo)"
mkdir -p "$REPO/packages/connectors/beeper-out/scripts"
cat > "$REPO/packages/connectors/beeper-out/scripts/x.sh" <<'SH'
#!/usr/bin/env bash
# refuse: chat id not in profile ## Notify self-only chat
curl -X POST "http://localhost:23373/v1/chats/1/messages" -d "$1"
SH
commit_extra "$REPO"
out="$(run_guard "$REPO" never-send)"
status=$?
if [ "$status" -eq 0 ] && ! printf '%s' "$out" | grep -q 'FAIL:'; then
    pass "never-send: allows beeper-out/scripts POST when the self-only guard string is present"
else
    fail "never-send: expected pass, got status=$status output=$out"
fi
rm -rf "$REPO"

REPO="$(new_repo)"
mkdir -p "$REPO/packages/connectors/beeper-out/scripts"
cat > "$REPO/packages/connectors/beeper-out/scripts/x.sh" <<'SH'
#!/usr/bin/env bash
curl -X POST "http://localhost:23373/v1/chats/1/messages" -d "$1"
SH
commit_extra "$REPO"
out="$(run_guard "$REPO" never-send)"
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL: never-send'; then
    pass "never-send: fails beeper-out/scripts POST without the self-only guard string"
else
    fail "never-send: expected FAIL, got status=$status output=$out"
fi
rm -rf "$REPO"

REPO="$(new_repo)"
printf '#!/usr/bin/env bash\ncurl -X POST "http://localhost:23373/v1/chats/1/messages"\n' \
    > "$REPO/packages/attention/foo.sh"
commit_extra "$REPO"
out="$(run_guard "$REPO" never-send)"
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL: never-send:'; then
    pass "never-send: fails a raw Beeper messages POST outside beeper-out/scripts"
else
    fail "never-send: expected FAIL, got status=$status output=$out"
fi
rm -rf "$REPO"

# ===========================================================================
# 8. no-enrichment
# ===========================================================================
REPO="$(new_repo)"
mkdir -p "$REPO/packages/ingestion/scripts"
printf 'curl https://api.clearbit.com/v2/people/find\n' > "$REPO/packages/ingestion/scripts/lookup.sh"
commit_extra "$REPO"
out="$(run_guard "$REPO" no-enrichment)"
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL: no-enrichment:'; then
    pass "no-enrichment: fails on a scraping/enrichment host reference"
else
    fail "no-enrichment: expected FAIL, got status=$status output=$out"
fi
rm -rf "$REPO"

REPO="$(new_repo)"
mkdir -p "$REPO/packages/connectors/gmail-in/fixtures"
printf 'subject: You appeared in a search — linkedin.com/in/jane-doe viewed your profile\n' \
    > "$REPO/packages/connectors/gmail-in/fixtures/notification.eml"
commit_extra "$REPO"
out="$(run_guard "$REPO" no-enrichment)"
status=$?
if [ "$status" -eq 0 ] && ! printf '%s' "$out" | grep -q 'FAIL:'; then
    pass "no-enrichment: scopes linkedin.com/in/ out of fixtures/ (notification emails)"
else
    fail "no-enrichment: expected pass, got status=$status output=$out"
fi
rm -rf "$REPO"

# ===========================================================================
# 9. gitignore-baseline
# ===========================================================================
REPO="$(new_repo)"
cat > "$REPO/.gitignore" <<'GI'
data/*
!data/README.md
node_modules/
GI
commit_extra "$REPO"
out="$(run_guard "$REPO" gitignore-baseline)"
status=$?
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL: gitignore-baseline:'; then
    pass "gitignore-baseline: fails when required lines are missing"
else
    fail "gitignore-baseline: expected FAIL, got status=$status output=$out"
fi
rm -rf "$REPO"

# ===========================================================================
# 10. self-exclusion: the guard must not trip on its own tracked source
#     (secret-pattern literals in oss-guard.sh, synthetic-violation fixture
#     strings in this test file) once those files are committed and tracked
#     — this is exactly the gap that let a "clean" local run (where these
#     files were still untracked, so `git grep` never saw them) diverge from
#     a CI run against a fresh clone where they're committed.
# ===========================================================================
REPO="$(new_repo)"
mkdir -p "$REPO/.claude/scripts/tests"
cp "$GUARD" "$REPO/.claude/scripts/oss-guard.sh"
cp "$SCRIPT_DIR/run-oss-guard-tests.sh" "$REPO/.claude/scripts/tests/run-oss-guard-tests.sh"
chmod +x "$REPO/.claude/scripts/oss-guard.sh" "$REPO/.claude/scripts/tests/run-oss-guard-tests.sh"
commit_extra "$REPO"
out="$(run_guard "$REPO")"
status=$?
if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -q '^OK: oss-guard clean$'; then
    pass "self-exclusion: guard passes on a scratch repo tracking a copy of itself + its tests"
else
    fail "self-exclusion: expected exit 0 + OK line, got status=$status output=$out"
fi
rm -rf "$REPO"

# ===========================================================================
echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
