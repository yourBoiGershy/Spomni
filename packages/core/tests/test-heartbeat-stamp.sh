#!/usr/bin/env bash
# packages/core/tests/test-heartbeat-stamp.sh
#
# Covers packages/core/scripts/heartbeat-stamp.sh:
#   1. stamp writes valid JSON with the 5 contract keys and ok:true.
#   2. --fail records ok:false.
#   3. re-stamping the same routine overwrites stamped_at.
#   4. a routine name that doesn't match ^[a-z0-9-]+$ exits 2.
#   5. --cadence-hours 0 exits 2.
#   6. no leftover *.tmp.* files are left in heartbeats/ after a stamp.
#
# bash 3.2 portable (no associative arrays, no mapfile).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

HEARTBEAT_STAMP="$REPO_ROOT/packages/core/scripts/heartbeat-stamp.sh"

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

SCRATCH_DIRS=""

cleanup() {
  for d in $SCRATCH_DIRS; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

new_scratch_dir() {
  local dir
  dir="$(mktemp -d 2>/dev/null || mktemp -d -t 'heartbeat-stamp-test')"
  SCRATCH_DIRS="$SCRATCH_DIRS $dir"
  printf '%s\n' "$dir"
}

HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then
  HAVE_JQ=1
fi

if [ ! -x "$HEARTBEAT_STAMP" ]; then
  echo "SKIP: $HEARTBEAT_STAMP not found or not executable — cannot run heartbeat-stamp tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, heartbeat-stamp.sh missing"
  exit 1
fi

# ---------------------------------------------------------------------------
# assertion 1: stamp writes valid JSON with the 5 keys and ok:true
# ---------------------------------------------------------------------------

scratch1="$(new_scratch_dir)"
store1="$scratch1/store"
mkdir -p "$store1"

stamp_output1="$("$HEARTBEAT_STAMP" "$store1" nightly-sweep --cadence-hours 24 --now 2026-01-01T00:00:00Z 2>&1)"
stamp_exit1=$?
stamp_path1="$store1/heartbeats/nightly-sweep.json"

if [ "$stamp_exit1" -eq 0 ] && [ -f "$stamp_path1" ] && printf '%s' "$stamp_output1" | grep -qF "$stamp_path1"; then
  pass "stamp writes heartbeats/<routine>.json and prints the path"
else
  fail "stamp did not write the expected file or print its path (exit=$stamp_exit1)"
  echo "$stamp_output1"
fi

if [ "$HAVE_JQ" -eq 1 ]; then
  keys1="$(jq -r 'keys | sort | join(",")' "$stamp_path1" 2>/dev/null)"
  if [ "$keys1" = "cadence_hours,ok,routine,schema_version,stamped_at" ]; then
    pass "stamped JSON has exactly the 5 contract keys"
  else
    fail "stamped JSON keys unexpected: $keys1"
  fi

  ok1="$(jq -r '.ok' "$stamp_path1" 2>/dev/null)"
  sv1="$(jq -r '.schema_version' "$stamp_path1" 2>/dev/null)"
  routine1="$(jq -r '.routine' "$stamp_path1" 2>/dev/null)"
  cadence1="$(jq -r '.cadence_hours' "$stamp_path1" 2>/dev/null)"
  stamped_at1="$(jq -r '.stamped_at' "$stamp_path1" 2>/dev/null)"

  if [ "$ok1" = "true" ] && [ "$sv1" = "1.0.0" ] && [ "$routine1" = "nightly-sweep" ] \
    && [ "$cadence1" = "24" ] && [ "$stamped_at1" = "2026-01-01T00:00:00Z" ]
  then
    pass "stamped JSON values match: ok=true, schema_version=1.0.0, routine, cadence_hours, stamped_at"
  else
    fail "stamped JSON values unexpected (ok=$ok1 sv=$sv1 routine=$routine1 cadence=$cadence1 stamped_at=$stamped_at1)"
  fi
else
  echo "SKIP: jq not present — skipping JSON-shape assertions for assertion 1"
fi

# ---------------------------------------------------------------------------
# assertion 2: --fail records ok:false
# ---------------------------------------------------------------------------

scratch2="$(new_scratch_dir)"
store2="$scratch2/store"
mkdir -p "$store2"

stamp_output2="$("$HEARTBEAT_STAMP" "$store2" nightly-sweep --cadence-hours 24 --fail --now 2026-01-01T00:00:00Z 2>&1)"
stamp_exit2=$?
stamp_path2="$store2/heartbeats/nightly-sweep.json"

if [ "$stamp_exit2" -eq 0 ] && [ -f "$stamp_path2" ]; then
  pass "--fail stamp writes 0 exit"
else
  fail "--fail stamp did not succeed as expected (exit=$stamp_exit2)"
  echo "$stamp_output2"
fi

if [ "$HAVE_JQ" -eq 1 ]; then
  ok2="$(jq -r '.ok' "$stamp_path2" 2>/dev/null)"
  if [ "$ok2" = "false" ]; then
    pass "--fail records ok:false"
  else
    fail "--fail did not record ok:false (got ok=$ok2)"
  fi
else
  echo "SKIP: jq not present — skipping ok:false assertion"
fi

# ---------------------------------------------------------------------------
# assertion 3: re-stamping overwrites stamped_at
# ---------------------------------------------------------------------------

scratch3="$(new_scratch_dir)"
store3="$scratch3/store"
mkdir -p "$store3"

"$HEARTBEAT_STAMP" "$store3" nightly-sweep --cadence-hours 24 --now 2026-01-01T00:00:00Z >/dev/null 2>&1
"$HEARTBEAT_STAMP" "$store3" nightly-sweep --cadence-hours 24 --now 2026-01-02T00:00:00Z >/dev/null 2>&1
stamp_path3="$store3/heartbeats/nightly-sweep.json"

if [ "$HAVE_JQ" -eq 1 ]; then
  stamped_at3="$(jq -r '.stamped_at' "$stamp_path3" 2>/dev/null)"
  if [ "$stamped_at3" = "2026-01-02T00:00:00Z" ]; then
    pass "re-stamping the same routine overwrites stamped_at"
  else
    fail "re-stamping did not overwrite stamped_at (got $stamped_at3)"
  fi
else
  if grep -qF '2026-01-02T00:00:00Z' "$stamp_path3" && ! grep -qF '2026-01-01T00:00:00Z' "$stamp_path3"; then
    pass "re-stamping the same routine overwrites stamped_at"
  else
    fail "re-stamping did not overwrite stamped_at"
  fi
fi

# ---------------------------------------------------------------------------
# assertion 4: bad routine name exits 2
# ---------------------------------------------------------------------------

scratch4="$(new_scratch_dir)"
store4="$scratch4/store"
mkdir -p "$store4"

stamp_output4="$("$HEARTBEAT_STAMP" "$store4" Bad_Name --cadence-hours 24 2>&1)"
stamp_exit4=$?

if [ "$stamp_exit4" -eq 2 ]; then
  pass "a routine name that fails ^[a-z0-9-]+\$ exits 2"
else
  fail "bad routine name did not exit 2 (exit=$stamp_exit4)"
  echo "$stamp_output4"
fi

# ---------------------------------------------------------------------------
# assertion 5: --cadence-hours 0 exits 2
# ---------------------------------------------------------------------------

scratch5="$(new_scratch_dir)"
store5="$scratch5/store"
mkdir -p "$store5"

stamp_output5="$("$HEARTBEAT_STAMP" "$store5" nightly-sweep --cadence-hours 0 2>&1)"
stamp_exit5=$?

if [ "$stamp_exit5" -eq 2 ]; then
  pass "--cadence-hours 0 exits 2"
else
  fail "--cadence-hours 0 did not exit 2 (exit=$stamp_exit5)"
  echo "$stamp_output5"
fi

# ---------------------------------------------------------------------------
# assertion 6: no leftover *.tmp.* files in heartbeats/
# ---------------------------------------------------------------------------

scratch6="$(new_scratch_dir)"
store6="$scratch6/store"
mkdir -p "$store6"

"$HEARTBEAT_STAMP" "$store6" nightly-sweep --cadence-hours 24 >/dev/null 2>&1
leftover6="$(find "$store6/heartbeats" -name '*.tmp.*' 2>/dev/null)"

if [ -z "$leftover6" ]; then
  pass "no leftover *.tmp.* files in heartbeats/ after a stamp"
else
  fail "leftover tmp files found in heartbeats/: $leftover6"
fi

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
