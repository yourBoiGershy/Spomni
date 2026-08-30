#!/usr/bin/env bash
# packages/attention/tests/run-staleness-tests.sh
#
# Test suite for packages/attention/scripts/staleness.sh — the deterministic
# staleness check for the `sweep` skill (routine heartbeats +
# sync-scheduler connector lanes). Infrastructure for the *noticing* cost of
# a dead schedule: a killed routine/lane yields exactly one staleness
# wake-up; restored -> none further; re-run never duplicates while one is
# pending.
#
# Scenarios (all built against mktemp scratch stores, never against
# packages/core/fixtures/store directly — always `cp -R` a fresh copy):
#   1. stale routine heartbeat -> exactly one pending wake-up
#      (status/origin/signal-type/[[self]])
#   2. fresh routine heartbeat -> ok, no wake-up
#   3. re-run same inputs -> already-pending, still exactly one
#   4. that wake-up dismissed, then re-run -> a NEW one is created (total 2:
#      one dismissed, one pending)
#   5. connector lanes: stale/fresh/disabled-stale/never-run/missing-lanes.tsv
#   6. --dry-run on a stale store creates nothing
#   7. missing heartbeats/ dir and empty --sync-data-dir -> exit 0, silent
#   8. validate-store.sh clean on the final store
#   9. zero-yield capture lanes (section 3): >=4 ok/events=0 runs in 24h ->
#      one <lane>-yield wake-up; re-run -> already-pending; any events>0 ->
#      ok; <4 ok runs -> never-run; runs older than 24h don't count;
#      backfill-*/non-ok outcomes are ignored; --dry-run creates nothing;
#      the ordinary lane-staleness check (section 2) for the same lane
#      still runs alongside it
#
# bash 3.2 portable (no associative arrays, no mapfile) — must run under
# macOS's stock /bin/bash, invocable from anywhere.

set -u

# --- resolve repo root relative to this script, not the caller's cwd ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

STALENESS="$REPO_ROOT/packages/attention/scripts/staleness.sh"
VALIDATOR="$REPO_ROOT/packages/core/scripts/validate-store.sh"
FIXTURE_STORE="$REPO_ROOT/packages/core/fixtures/store"

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

skip() {
  echo "SKIP: $1"
}

summary_and_exit() {
  echo ""
  echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"
  if [ "$FAIL_COUNT" -eq 0 ]; then
    exit 0
  else
    exit 1
  fi
}

for req in "$STALENESS" "$VALIDATOR" "$FIXTURE_STORE"; do
  if [ ! -e "$req" ]; then
    fail "required path missing: $req"
    summary_and_exit
  fi
done

if [ ! -x "$STALENESS" ]; then
  fail "$STALENESS exists but is not executable"
  summary_and_exit
fi

TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t 'staleness-test')"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

NOW="2026-08-30T12:00:00Z"

# new_store <dir> — a fresh scratch store copied from the committed fixture
new_store() {
  local dir="$1"
  mkdir -p "$dir"
  cp -R "$FIXTURE_STORE/." "$dir/"
}

# count_wakeups <dir> <name> — count of wakeups/*.md whose frontmatter has
# source-signal: staleness:<name>
count_wakeups() {
  local dir="$1" name="$2"
  grep -l "^source-signal: staleness:${name}\$" "$dir"/wakeups/*.md 2>/dev/null | wc -l | tr -d ' '
}

# =============================================================================
# Scenario 1: stale routine heartbeat -> exactly one pending wake-up
# =============================================================================

S1_DIR="$TMP_ROOT/s1-stale-routine"
new_store "$S1_DIR"
mkdir -p "$S1_DIR/heartbeats"
cat > "$S1_DIR/heartbeats/daily-attention.json" <<'EOF'
{"schema_version":"1.0.0","routine":"daily-attention","stamped_at":"2026-08-27T12:00:00Z","cadence_hours":24,"ok":true}
EOF

S1_SYNC_DIR="$TMP_ROOT/s1-sync-data-empty"
mkdir -p "$S1_SYNC_DIR"

s1_out="$("$STALENESS" "$S1_DIR" --sync-data-dir "$S1_SYNC_DIR" --now "$NOW" 2>&1)"
s1_status=$?

if [ "$s1_status" -eq 0 ]; then
  pass "stale routine: exits 0"
else
  fail "stale routine: exited $s1_status: $s1_out"
fi

if printf '%s\n' "$s1_out" | grep -q '^staleness: daily-attention stale'; then
  pass "stale routine: output line reports 'daily-attention stale'"
else
  fail "stale routine: expected a 'daily-attention stale' line, got: $s1_out"
fi

S1_COUNT="$(count_wakeups "$S1_DIR" "daily-attention")"
if [ "$S1_COUNT" = "1" ]; then
  pass "stale routine: exactly one wake-up file created"
else
  fail "stale routine: expected exactly 1 wake-up file, got $S1_COUNT"
fi

S1_WAKEUP="$(grep -l "^source-signal: staleness:daily-attention\$" "$S1_DIR"/wakeups/*.md 2>/dev/null | head -n1)"
if [ -n "$S1_WAKEUP" ] && grep -q '^status: pending$' "$S1_WAKEUP" \
  && grep -q '^origin: standing$' "$S1_WAKEUP" \
  && grep -q '^signal-type: staleness$' "$S1_WAKEUP" \
  && grep -q '\[\[self\]\]' "$S1_WAKEUP"; then
  pass "stale routine: wake-up has status: pending, origin: standing, signal-type: staleness, [[self]]"
else
  fail "stale routine: wake-up file missing expected fields: $(cat "$S1_WAKEUP" 2>&1)"
fi

# =============================================================================
# Scenario 2: fresh routine heartbeat -> ok, no wake-up
# =============================================================================

S2_DIR="$TMP_ROOT/s2-fresh-routine"
new_store "$S2_DIR"
mkdir -p "$S2_DIR/heartbeats"
cat > "$S2_DIR/heartbeats/weekly-review.json" <<'EOF'
{"schema_version":"1.0.0","routine":"weekly-review","stamped_at":"2026-08-30T11:00:00Z","cadence_hours":24,"ok":true}
EOF

S2_SYNC_DIR="$TMP_ROOT/s2-sync-data-empty"
mkdir -p "$S2_SYNC_DIR"

s2_out="$("$STALENESS" "$S2_DIR" --sync-data-dir "$S2_SYNC_DIR" --now "$NOW" 2>&1)"
s2_status=$?

if [ "$s2_status" -eq 0 ] && printf '%s\n' "$s2_out" | grep -q '^staleness: weekly-review ok'; then
  pass "fresh routine: exits 0 and reports ok"
else
  fail "fresh routine: unexpected result (status=$s2_status): $s2_out"
fi

S2_COUNT="$(count_wakeups "$S2_DIR" "weekly-review")"
if [ "$S2_COUNT" = "0" ]; then
  pass "fresh routine: no wake-up created"
else
  fail "fresh routine: expected 0 wake-ups, got $S2_COUNT"
fi

# =============================================================================
# Scenario 3: re-run same inputs -> already-pending, still exactly one
# =============================================================================

s3_out="$("$STALENESS" "$S1_DIR" --sync-data-dir "$S1_SYNC_DIR" --now "$NOW" 2>&1)"
s3_status=$?

if [ "$s3_status" -eq 0 ] && printf '%s\n' "$s3_out" | grep -q '^staleness: daily-attention already-pending'; then
  pass "re-run: reports already-pending"
else
  fail "re-run: unexpected result (status=$s3_status): $s3_out"
fi

S3_COUNT="$(count_wakeups "$S1_DIR" "daily-attention")"
if [ "$S3_COUNT" = "1" ]; then
  pass "re-run: still exactly one wake-up file"
else
  fail "re-run: expected exactly 1 wake-up file, got $S3_COUNT"
fi

# =============================================================================
# Scenario 4: dismiss the pending wake-up, then re-run -> a NEW one is
# created (total 2: one dismissed, one pending)
# =============================================================================

if grep -q '^dismiss-reason:$' "$S1_WAKEUP"; then
  sed -i.bak \
    -e 's/^status: pending$/status: dismissed/' \
    -e 's/^dismiss-reason:$/dismiss-reason: already-handled/' \
    "$S1_WAKEUP"
  rm -f "$S1_WAKEUP.bak"
else
  fail "scenario 4 setup: $S1_WAKEUP does not carry a blank dismiss-reason: field to fill in"
fi

s4_out="$("$STALENESS" "$S1_DIR" --sync-data-dir "$S1_SYNC_DIR" --now "$NOW" 2>&1)"
s4_status=$?

if [ "$s4_status" -eq 0 ] && printf '%s\n' "$s4_out" | grep -q '^staleness: daily-attention stale'; then
  pass "after dismiss: re-run creates a fresh stale wake-up"
else
  fail "after dismiss: unexpected result (status=$s4_status): $s4_out"
fi

S4_COUNT="$(count_wakeups "$S1_DIR" "daily-attention")"
if [ "$S4_COUNT" = "2" ]; then
  pass "after dismiss: total of two wake-up files (one dismissed, one pending)"
else
  fail "after dismiss: expected exactly 2 wake-up files, got $S4_COUNT"
fi

S4_PENDING_COUNT="$(grep -l "^source-signal: staleness:daily-attention\$" "$S1_DIR"/wakeups/*.md 2>/dev/null | xargs grep -l '^status: pending$' 2>/dev/null | wc -l | tr -d ' ')"
S4_DISMISSED_COUNT="$(grep -l "^source-signal: staleness:daily-attention\$" "$S1_DIR"/wakeups/*.md 2>/dev/null | xargs grep -l '^status: dismissed$' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$S4_PENDING_COUNT" = "1" ] && [ "$S4_DISMISSED_COUNT" = "1" ]; then
  pass "after dismiss: exactly one pending and one dismissed daily-attention wake-up"
else
  fail "after dismiss: expected 1 pending + 1 dismissed, got pending=$S4_PENDING_COUNT dismissed=$S4_DISMISSED_COUNT"
fi

# =============================================================================
# Scenario 5: connector lanes
# =============================================================================

S5_DIR="$TMP_ROOT/s5-lanes"
new_store "$S5_DIR"

S5_SYNC_DIR="$TMP_ROOT/s5-sync-data"
mkdir -p "$S5_SYNC_DIR/connectors/sync-scheduler/state"

cat > "$S5_SYNC_DIR/connectors/sync-scheduler/lanes.tsv" <<'EOF'
# lane	interval_seconds	enabled	command
gmail-in	3600	true	/bin/true
gmail-fresh	3600	true	/bin/true
gmail-disabled	3600	false	/bin/true
gmail-never	3600	true	/bin/true
EOF

# gmail-in: last_end ~36h before --now, threshold 2h -> stale
printf '2026-08-29T00:00:00Z\t2026-08-29T00:05:00Z\t0\n' > "$S5_SYNC_DIR/connectors/sync-scheduler/state/gmail-in.tsv"
# gmail-fresh: last_end 10 minutes before --now -> ok
printf '2026-08-30T11:45:00Z\t2026-08-30T11:50:00Z\t0\n' > "$S5_SYNC_DIR/connectors/sync-scheduler/state/gmail-fresh.tsv"
# gmail-disabled: same stale timestamp as gmail-in, but lane is disabled
printf '2026-08-29T00:00:00Z\t2026-08-29T00:05:00Z\t0\n' > "$S5_SYNC_DIR/connectors/sync-scheduler/state/gmail-disabled.tsv"
# gmail-never: no state file at all

s5_out="$("$STALENESS" "$S5_DIR" --sync-data-dir "$S5_SYNC_DIR" --now "$NOW" 2>&1)"
s5_status=$?

if [ "$s5_status" -eq 0 ]; then
  pass "lanes: exits 0"
else
  fail "lanes: exited $s5_status: $s5_out"
fi

if printf '%s\n' "$s5_out" | grep -q '^staleness: gmail-in stale'; then
  pass "lanes: stale lane reported"
else
  fail "lanes: expected 'gmail-in stale', got: $s5_out"
fi

S5_IN_COUNT="$(count_wakeups "$S5_DIR" "gmail-in")"
if [ "$S5_IN_COUNT" = "1" ]; then
  pass "lanes: stale lane creates exactly one wake-up"
else
  fail "lanes: expected 1 wake-up for gmail-in, got $S5_IN_COUNT"
fi

if printf '%s\n' "$s5_out" | grep -q '^staleness: gmail-fresh ok'; then
  pass "lanes: fresh lane reported ok"
else
  fail "lanes: expected 'gmail-fresh ok', got: $s5_out"
fi

S5_FRESH_COUNT="$(count_wakeups "$S5_DIR" "gmail-fresh")"
if [ "$S5_FRESH_COUNT" = "0" ]; then
  pass "lanes: fresh lane creates no wake-up"
else
  fail "lanes: expected 0 wake-ups for gmail-fresh, got $S5_FRESH_COUNT"
fi

if printf '%s\n' "$s5_out" | grep -q 'gmail-disabled'; then
  fail "lanes: disabled lane should not appear in output at all: $s5_out"
else
  pass "lanes: disabled lane produces no output line"
fi

S5_DISABLED_COUNT="$(count_wakeups "$S5_DIR" "gmail-disabled")"
if [ "$S5_DISABLED_COUNT" = "0" ]; then
  pass "lanes: disabled stale lane creates no wake-up"
else
  fail "lanes: expected 0 wake-ups for gmail-disabled, got $S5_DISABLED_COUNT"
fi

if printf '%s\n' "$s5_out" | grep -q '^staleness: gmail-never never-run'; then
  pass "lanes: no-state-file lane reported never-run"
else
  fail "lanes: expected 'gmail-never never-run', got: $s5_out"
fi

S5_NEVER_COUNT="$(count_wakeups "$S5_DIR" "gmail-never")"
if [ "$S5_NEVER_COUNT" = "0" ]; then
  pass "lanes: never-run lane creates no wake-up"
else
  fail "lanes: expected 0 wake-ups for gmail-never, got $S5_NEVER_COUNT"
fi

# missing lanes.tsv entirely -> exit 0, no lane lines
S5B_DIR="$TMP_ROOT/s5b-no-lanes-tsv"
new_store "$S5B_DIR"
S5B_SYNC_DIR="$TMP_ROOT/s5b-sync-data-empty"
mkdir -p "$S5B_SYNC_DIR"

s5b_out="$("$STALENESS" "$S5B_DIR" --sync-data-dir "$S5B_SYNC_DIR" --now "$NOW" 2>&1)"
s5b_status=$?

if [ "$s5b_status" -eq 0 ] && [ -z "$s5b_out" ]; then
  pass "lanes: missing lanes.tsv entirely -> exit 0, no lane lines"
else
  fail "lanes: missing lanes.tsv case unexpected (status=$s5b_status): $s5b_out"
fi

# =============================================================================
# Scenario 6: --dry-run creates nothing
# =============================================================================

S6_DIR="$TMP_ROOT/s6-dry-run"
new_store "$S6_DIR"
mkdir -p "$S6_DIR/heartbeats"
cat > "$S6_DIR/heartbeats/daily-attention.json" <<'EOF'
{"schema_version":"1.0.0","routine":"daily-attention","stamped_at":"2026-08-27T12:00:00Z","cadence_hours":24,"ok":true}
EOF
S6_SYNC_DIR="$TMP_ROOT/s6-sync-data-empty"
mkdir -p "$S6_SYNC_DIR"

S6_FILES_BEFORE="$(find "$S6_DIR/wakeups" -type f | sort)"

s6_out="$("$STALENESS" "$S6_DIR" --sync-data-dir "$S6_SYNC_DIR" --now "$NOW" --dry-run 2>&1)"
s6_status=$?

if [ "$s6_status" -eq 0 ] && printf '%s\n' "$s6_out" | grep -q '^staleness: daily-attention stale'; then
  pass "dry-run: exits 0 and still reports stale"
else
  fail "dry-run: unexpected result (status=$s6_status): $s6_out"
fi

S6_FILES_AFTER="$(find "$S6_DIR/wakeups" -type f | sort)"
if [ "$S6_FILES_BEFORE" = "$S6_FILES_AFTER" ]; then
  pass "dry-run: creates zero files"
else
  fail "dry-run: wakeups/ file listing changed:"
  diff <(printf '%s\n' "$S6_FILES_BEFORE") <(printf '%s\n' "$S6_FILES_AFTER")
fi

# =============================================================================
# Scenario 7: missing heartbeats/ dir and empty --sync-data-dir -> exit 0,
# no output, no errors
# =============================================================================

S7_DIR="$TMP_ROOT/s7-nothing-to-check"
new_store "$S7_DIR"
rm -rf "$S7_DIR/heartbeats"
S7_SYNC_DIR="$TMP_ROOT/s7-sync-data-empty"
mkdir -p "$S7_SYNC_DIR"

s7_stdout="$("$STALENESS" "$S7_DIR" --sync-data-dir "$S7_SYNC_DIR" --now "$NOW" 2>"$TMP_ROOT/s7-stderr")"
s7_status=$?
s7_stderr="$(cat "$TMP_ROOT/s7-stderr")"

if [ "$s7_status" -eq 0 ]; then
  pass "nothing to check: exits 0"
else
  fail "nothing to check: exited $s7_status, stderr: $s7_stderr"
fi

if [ -z "$s7_stdout" ] && [ -z "$s7_stderr" ]; then
  pass "nothing to check: no stdout, no stderr"
else
  fail "nothing to check: expected silence, got stdout=[$s7_stdout] stderr=[$s7_stderr]"
fi

# =============================================================================
# Scenario 8: validate-store.sh clean on the final store
# =============================================================================

s8_out="$("$VALIDATOR" "$S1_DIR" 2>&1)"
s8_status=$?

if [ "$s8_status" -eq 0 ]; then
  pass "validate-store.sh clean after the staleness lifecycle"
else
  if printf '%s\n' "$s8_out" | grep -q '\[\[self\]\] does not resolve to people/self.md' \
    && [ "$(printf '%s\n' "$s8_out" | grep -vc '\[\[self\]\] does not resolve to people/self.md')" -le 1 ]; then
    skip "validate-store.sh: only finding is the [[self]] slug (validator self-slug patch pending): $s8_out"
  else
    fail "validate-store.sh reported findings (status=$s8_status): $s8_out"
  fi
fi

# =============================================================================
# Scenario 9: zero-yield capture lanes (section 3)
# =============================================================================

# --- 9a/9h: 6 ok/events=0 runs in 24h -> stale wake-up, AND the ordinary
# lane-staleness check (section 2, fresh state) still reports ok alongside it
# =============================================================================

S9A_DIR="$TMP_ROOT/s9a-zero-yield-stale"
new_store "$S9A_DIR"

S9A_SYNC_DIR="$TMP_ROOT/s9a-sync-data"
mkdir -p "$S9A_SYNC_DIR/connectors/sync-scheduler/state"
mkdir -p "$S9A_SYNC_DIR/connectors/beeper-in"

cat > "$S9A_SYNC_DIR/connectors/sync-scheduler/lanes.tsv" <<'EOF'
# lane	interval_seconds	enabled	command
beeper	900	true	/bin/true
EOF

# fresh state file -> section 2's ordinary check should say "beeper ok"
printf '2026-08-30T11:50:00Z\t2026-08-30T11:55:00Z\t0\n' > "$S9A_SYNC_DIR/connectors/sync-scheduler/state/beeper.tsv"

cat > "$S9A_SYNC_DIR/connectors/beeper-in/runs.log" <<'EOF'
2026-08-29T13:00:00Z ok chats=1 events=0 quarantined=0
2026-08-29T15:00:00Z ok chats=1 events=0 quarantined=0
2026-08-29T17:00:00Z ok chats=1 events=0 quarantined=0
2026-08-29T19:00:00Z ok chats=1 events=0 quarantined=0
2026-08-29T21:00:00Z ok chats=1 events=0 quarantined=0
2026-08-29T23:00:00Z ok chats=1 events=0 quarantined=0
EOF

s9a_out="$("$STALENESS" "$S9A_DIR" --sync-data-dir "$S9A_SYNC_DIR" --now "$NOW" 2>&1)"
s9a_status=$?

if [ "$s9a_status" -eq 0 ]; then
  pass "zero-yield stale: exits 0"
else
  fail "zero-yield stale: exited $s9a_status: $s9a_out"
fi

if printf '%s\n' "$s9a_out" | grep -q '^staleness: beeper-yield stale'; then
  pass "zero-yield stale: output line reports 'beeper-yield stale'"
else
  fail "zero-yield stale: expected a 'beeper-yield stale' line, got: $s9a_out"
fi

if printf '%s\n' "$s9a_out" | grep -q '^staleness: beeper ok'; then
  pass "zero-yield stale: ordinary lane-staleness check (section 2) still reports 'beeper ok' alongside it"
else
  fail "zero-yield stale: expected 'beeper ok' from the ordinary lane check too, got: $s9a_out"
fi

S9A_COUNT="$(count_wakeups "$S9A_DIR" "beeper-yield")"
if [ "$S9A_COUNT" = "1" ]; then
  pass "zero-yield stale: exactly one wake-up file created"
else
  fail "zero-yield stale: expected exactly 1 wake-up file, got $S9A_COUNT"
fi

S9A_WAKEUP="$(grep -l "^source-signal: staleness:beeper-yield\$" "$S9A_DIR"/wakeups/*.md 2>/dev/null | head -n1)"
if [ -n "$S9A_WAKEUP" ] && grep -q '^status: pending$' "$S9A_WAKEUP" \
  && grep -q '^origin: standing$' "$S9A_WAKEUP" \
  && grep -q '^signal-type: staleness$' "$S9A_WAKEUP" \
  && grep -q '\[\[self\]\]' "$S9A_WAKEUP"; then
  pass "zero-yield stale: wake-up has status: pending, origin: standing, signal-type: staleness, [[self]]"
else
  fail "zero-yield stale: wake-up file missing expected fields: $(cat "$S9A_WAKEUP" 2>&1)"
fi

# --- 9b: re-run same inputs -> already-pending, still exactly one ----------

s9b_out="$("$STALENESS" "$S9A_DIR" --sync-data-dir "$S9A_SYNC_DIR" --now "$NOW" 2>&1)"
s9b_status=$?

if [ "$s9b_status" -eq 0 ] && printf '%s\n' "$s9b_out" | grep -q '^staleness: beeper-yield already-pending'; then
  pass "zero-yield re-run: reports already-pending"
else
  fail "zero-yield re-run: unexpected result (status=$s9b_status): $s9b_out"
fi

S9B_COUNT="$(count_wakeups "$S9A_DIR" "beeper-yield")"
if [ "$S9B_COUNT" = "1" ]; then
  pass "zero-yield re-run: still exactly one wake-up file"
else
  fail "zero-yield re-run: expected exactly 1 wake-up file, got $S9B_COUNT"
fi

# --- 9c: 6 ok lines, one with events=3 -> ok, no wake-up -------------------

S9C_DIR="$TMP_ROOT/s9c-zero-yield-ok"
new_store "$S9C_DIR"

S9C_SYNC_DIR="$TMP_ROOT/s9c-sync-data"
mkdir -p "$S9C_SYNC_DIR/connectors/sync-scheduler/state"
mkdir -p "$S9C_SYNC_DIR/connectors/beeper-in"

cat > "$S9C_SYNC_DIR/connectors/sync-scheduler/lanes.tsv" <<'EOF'
# lane	interval_seconds	enabled	command
beeper	900	true	/bin/true
EOF

cat > "$S9C_SYNC_DIR/connectors/beeper-in/runs.log" <<'EOF'
2026-08-29T13:00:00Z ok chats=1 events=0 quarantined=0
2026-08-29T15:00:00Z ok chats=1 events=3 quarantined=0
2026-08-29T17:00:00Z ok chats=1 events=0 quarantined=0
2026-08-29T19:00:00Z ok chats=1 events=0 quarantined=0
2026-08-29T21:00:00Z ok chats=1 events=0 quarantined=0
2026-08-29T23:00:00Z ok chats=1 events=0 quarantined=0
EOF

s9c_out="$("$STALENESS" "$S9C_DIR" --sync-data-dir "$S9C_SYNC_DIR" --now "$NOW" 2>&1)"
s9c_status=$?

if [ "$s9c_status" -eq 0 ] && printf '%s\n' "$s9c_out" | grep -q '^staleness: beeper-yield ok (6 runs, 3 events in 24h)'; then
  pass "zero-yield with events: reports ok with correct run/event counts"
else
  fail "zero-yield with events: unexpected result (status=$s9c_status): $s9c_out"
fi

S9C_COUNT="$(count_wakeups "$S9C_DIR" "beeper-yield")"
if [ "$S9C_COUNT" = "0" ]; then
  pass "zero-yield with events: no wake-up created"
else
  fail "zero-yield with events: expected 0 wake-ups, got $S9C_COUNT"
fi

# --- 9d: only 3 ok lines -> never-run --------------------------------------

S9D_DIR="$TMP_ROOT/s9d-zero-yield-never-run"
new_store "$S9D_DIR"

S9D_SYNC_DIR="$TMP_ROOT/s9d-sync-data"
mkdir -p "$S9D_SYNC_DIR/connectors/sync-scheduler/state"
mkdir -p "$S9D_SYNC_DIR/connectors/beeper-in"

cat > "$S9D_SYNC_DIR/connectors/sync-scheduler/lanes.tsv" <<'EOF'
# lane	interval_seconds	enabled	command
beeper	900	true	/bin/true
EOF

cat > "$S9D_SYNC_DIR/connectors/beeper-in/runs.log" <<'EOF'
2026-08-29T13:00:00Z ok chats=1 events=0 quarantined=0
2026-08-29T15:00:00Z ok chats=1 events=0 quarantined=0
2026-08-29T17:00:00Z ok chats=1 events=0 quarantined=0
EOF

s9d_out="$("$STALENESS" "$S9D_DIR" --sync-data-dir "$S9D_SYNC_DIR" --now "$NOW" 2>&1)"
s9d_status=$?

if [ "$s9d_status" -eq 0 ] && printf '%s\n' "$s9d_out" | grep -q '^staleness: beeper-yield never-run (3 runs in 24h, need 4)'; then
  pass "zero-yield too few runs: reports never-run with count"
else
  fail "zero-yield too few runs: unexpected result (status=$s9d_status): $s9d_out"
fi

S9D_COUNT="$(count_wakeups "$S9D_DIR" "beeper-yield")"
if [ "$S9D_COUNT" = "0" ]; then
  pass "zero-yield too few runs: no wake-up created"
else
  fail "zero-yield too few runs: expected 0 wake-ups, got $S9D_COUNT"
fi

# --- 9e: 6 zero-event lines but all older than 24h -> never-run (0 runs) --

S9E_DIR="$TMP_ROOT/s9e-zero-yield-stale-runs"
new_store "$S9E_DIR"

S9E_SYNC_DIR="$TMP_ROOT/s9e-sync-data"
mkdir -p "$S9E_SYNC_DIR/connectors/sync-scheduler/state"
mkdir -p "$S9E_SYNC_DIR/connectors/beeper-in"

cat > "$S9E_SYNC_DIR/connectors/sync-scheduler/lanes.tsv" <<'EOF'
# lane	interval_seconds	enabled	command
beeper	900	true	/bin/true
EOF

# all timestamps well before the 24h window (now - 86400 = 2026-08-29T12:00:00Z)
cat > "$S9E_SYNC_DIR/connectors/beeper-in/runs.log" <<'EOF'
2026-08-27T13:00:00Z ok chats=1 events=0 quarantined=0
2026-08-27T15:00:00Z ok chats=1 events=0 quarantined=0
2026-08-27T17:00:00Z ok chats=1 events=0 quarantined=0
2026-08-27T19:00:00Z ok chats=1 events=0 quarantined=0
2026-08-27T21:00:00Z ok chats=1 events=0 quarantined=0
2026-08-27T23:00:00Z ok chats=1 events=0 quarantined=0
EOF

s9e_out="$("$STALENESS" "$S9E_DIR" --sync-data-dir "$S9E_SYNC_DIR" --now "$NOW" 2>&1)"
s9e_status=$?

if [ "$s9e_status" -eq 0 ] && printf '%s\n' "$s9e_out" | grep -q '^staleness: beeper-yield never-run (0 runs in 24h, need 4)'; then
  pass "zero-yield stale runs: lines older than 24h don't count -> never-run (0 runs)"
else
  fail "zero-yield stale runs: unexpected result (status=$s9e_status): $s9e_out"
fi

S9E_COUNT="$(count_wakeups "$S9E_DIR" "beeper-yield")"
if [ "$S9E_COUNT" = "0" ]; then
  pass "zero-yield stale runs: no wake-up created"
else
  fail "zero-yield stale runs: expected 0 wake-ups, got $S9E_COUNT"
fi

# --- 9f: backfill-*/non-ok outcomes are ignored ----------------------------

S9F_DIR="$TMP_ROOT/s9f-zero-yield-ignored-outcomes"
new_store "$S9F_DIR"

S9F_SYNC_DIR="$TMP_ROOT/s9f-sync-data"
mkdir -p "$S9F_SYNC_DIR/connectors/sync-scheduler/state"
mkdir -p "$S9F_SYNC_DIR/connectors/beeper-in"

cat > "$S9F_SYNC_DIR/connectors/sync-scheduler/lanes.tsv" <<'EOF'
# lane	interval_seconds	enabled	command
beeper	900	true	/bin/true
EOF

# 4 valid ok/events=0 lines plus 2 lines that must be ignored: a
# backfill-prefixed outcome and a non-"ok" skip outcome. If either were
# counted, run_count would be 6 not 4 (still >= 4, but this scenario checks
# they're excluded from the count itself, not just that the verdict matches).
cat > "$S9F_SYNC_DIR/connectors/beeper-in/runs.log" <<'EOF'
2026-08-29T13:00:00Z backfill-skip-disabled chats=0 events=0 quarantined=0
2026-08-29T14:00:00Z skip-unreachable chats=0 events=0 quarantined=0
2026-08-29T15:00:00Z ok chats=1 events=0 quarantined=0
2026-08-29T17:00:00Z ok chats=1 events=0 quarantined=0
2026-08-29T19:00:00Z ok chats=1 events=0 quarantined=0
2026-08-29T21:00:00Z ok chats=1 events=0 quarantined=0
EOF

s9f_out="$("$STALENESS" "$S9F_DIR" --sync-data-dir "$S9F_SYNC_DIR" --now "$NOW" 2>&1)"
s9f_status=$?

if [ "$s9f_status" -eq 0 ] && printf '%s\n' "$s9f_out" | grep -q '^staleness: beeper-yield stale'; then
  pass "zero-yield ignored outcomes: backfill-*/non-ok lines excluded, remaining 4 ok/events=0 lines -> stale"
else
  fail "zero-yield ignored outcomes: unexpected result (status=$s9f_status): $s9f_out"
fi

S9F_COUNT="$(count_wakeups "$S9F_DIR" "beeper-yield")"
if [ "$S9F_COUNT" = "1" ]; then
  pass "zero-yield ignored outcomes: exactly one wake-up file created"
else
  fail "zero-yield ignored outcomes: expected exactly 1 wake-up file, got $S9F_COUNT"
fi

# --- 9g: --dry-run creates nothing ------------------------------------------

S9G_DIR="$TMP_ROOT/s9g-zero-yield-dry-run"
new_store "$S9G_DIR"

S9G_SYNC_DIR="$TMP_ROOT/s9g-sync-data"
mkdir -p "$S9G_SYNC_DIR/connectors/sync-scheduler/state"
mkdir -p "$S9G_SYNC_DIR/connectors/beeper-in"

cat > "$S9G_SYNC_DIR/connectors/sync-scheduler/lanes.tsv" <<'EOF'
# lane	interval_seconds	enabled	command
beeper	900	true	/bin/true
EOF

cat > "$S9G_SYNC_DIR/connectors/beeper-in/runs.log" <<'EOF'
2026-08-29T13:00:00Z ok chats=1 events=0 quarantined=0
2026-08-29T15:00:00Z ok chats=1 events=0 quarantined=0
2026-08-29T17:00:00Z ok chats=1 events=0 quarantined=0
2026-08-29T19:00:00Z ok chats=1 events=0 quarantined=0
2026-08-29T21:00:00Z ok chats=1 events=0 quarantined=0
2026-08-29T23:00:00Z ok chats=1 events=0 quarantined=0
EOF

S9G_FILES_BEFORE="$(find "$S9G_DIR/wakeups" -type f | sort)"

s9g_out="$("$STALENESS" "$S9G_DIR" --sync-data-dir "$S9G_SYNC_DIR" --now "$NOW" --dry-run 2>&1)"
s9g_status=$?

if [ "$s9g_status" -eq 0 ] && printf '%s\n' "$s9g_out" | grep -q '^staleness: beeper-yield stale (would create:'; then
  pass "zero-yield dry-run: exits 0 and reports stale with 'would create:'"
else
  fail "zero-yield dry-run: unexpected result (status=$s9g_status): $s9g_out"
fi

S9G_FILES_AFTER="$(find "$S9G_DIR/wakeups" -type f | sort)"
if [ "$S9G_FILES_BEFORE" = "$S9G_FILES_AFTER" ]; then
  pass "zero-yield dry-run: creates zero files"
else
  fail "zero-yield dry-run: wakeups/ file listing changed:"
  diff <(printf '%s\n' "$S9G_FILES_BEFORE") <(printf '%s\n' "$S9G_FILES_AFTER")
fi

summary_and_exit
