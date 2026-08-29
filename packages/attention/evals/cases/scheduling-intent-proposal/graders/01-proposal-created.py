#!/usr/bin/env python3
"""01-proposal-created.py — T3 grader for the scheduling-intent-proposal eval case.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused by this grader; the
     assertion is entirely about the resulting store contents).

Hand-derived expectation (from
packages/attention/tests/fixtures/scheduling-intent/clear-intent/expected/
proposal-wakeup.md's "Slot arithmetic" section, recomputed by hand — NOT
copied from any system's output, per eval-case.md's golden-tests-before-
prompts rule):

  - Theo's 2026-08-27 message ("are you free for lunch next week?") is an
    explicit mutual ask naming an activity (lunch) and a timeframe ("next
    week") -> confidence: high per specs/scheduling-intent.md's rubric.
  - Lunch intent class: 60m duration, 15m buffer each side, must start
    within 11:30-13:30, and >=48h out from detection (2026-08-29T09:00:00Z).
  - Monday 2026-08-31 is busy 11:00-14:00 (team sync) -- no lunch-length gap
    survives inside 11:30-13:30, so Monday is fully excluded.
  - Tuesday 2026-09-01 has a 10:30-14:00 free block (between the 09:00-10:30
    product review and the 14:00-15:30 pipeline sync), which comfortably
    fits 11:30-12:30 plus the 15m buffer on each side (11:15-12:45), and
    2026-09-01T11:30 is well past the 48h-notice floor.
  - No earlier qualifying day exists, so Tue 2026-09-01 11:30-12:30 is the
    unique earliest fitting slot -- this is the fixed, hardcoded golden
    window this grader checks against.

`./store/wakeups/` starts absent/empty in the fixture, so "new" here means
"any top-level *.md file at all" (mirrors the tier-drift-upward sibling
case's convention). `id`/`due`/`source-signal` are run-date-derived and not
byte-fixed by the fixture -- those are NOT asserted here; the slot window,
attendees, kind, and lifecycle-field nullness ARE, since those are fully
determined by the fixture regardless of when the sweep runs.
"""

import glob
import os
import re
import sys

EXPECTED_START = "2026-09-01T11:30:00-07:00"
EXPECTED_END = "2026-09-01T12:30:00-07:00"
EXPECTED_ATTENDEE = "theo-bramwell"


def parse_top_level(text):
    """Parse only non-indented `key: value` frontmatter lines."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}
    fm = {}
    for line in lines[1:]:
        if line.strip() == "---":
            break
        if line.startswith((" ", "\t")):
            continue
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    return fm


def parse_proposed_event(text):
    """Parse the indented `proposed-event:` mapping block, if present."""
    lines = text.splitlines()
    out = {}
    in_block = False
    for line in lines:
        if line.strip() == "---" and in_block:
            break
        if re.match(r"^proposed-event:\s*$", line):
            in_block = True
            continue
        if in_block:
            if not line.startswith((" ", "\t")):
                break
            m = re.match(r"^\s+([A-Za-z0-9_-]+):\s*(.*)$", line)
            if m:
                out[m.group(1)] = m.group(2).strip()
    return out


def main():
    if len(sys.argv) < 2:
        print("usage: 01-proposal-created.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    wakeups_dir = os.path.join(worked, "wakeups")

    if not os.path.isdir(wakeups_dir):
        print(f"FAIL: no wakeups/ dir in worked store {worked}")
        return 1

    candidates = sorted(glob.glob(os.path.join(wakeups_dir, "*.md")))

    before_dir = os.environ.get("RA_EVAL_BEFORE_DIR", "")
    if before_dir:
        before_wakeups = os.path.join(before_dir, "wakeups")
        before_names = set()
        if os.path.isdir(before_wakeups):
            before_names = {
                os.path.basename(p)
                for p in glob.glob(os.path.join(before_wakeups, "*.md"))
            }
        candidates = [c for c in candidates if os.path.basename(c) not in before_names]

    if len(candidates) != 1:
        print(f"FAIL: expected exactly one new wakeup file, found {len(candidates)}: {candidates}")
        return 1

    proposal_path = candidates[0]
    with open(proposal_path) as f:
        text = f.read()

    fm = parse_top_level(text)

    if fm.get("kind") != "event-proposal":
        print(f"FAIL: expected kind: event-proposal, got {fm.get('kind')!r} in {proposal_path}")
        return 1

    if fm.get("origin") != "signal":
        print(f"FAIL: expected origin: signal, got {fm.get('origin')!r} in {proposal_path}")
        return 1

    if fm.get("status") != "pending":
        print(f"FAIL: expected status: pending, got {fm.get('status')!r} in {proposal_path}")
        return 1

    source_signal = fm.get("source-signal", "")
    if not source_signal or source_signal.lower() in ("null", "~"):
        print(f"FAIL: expected non-null source-signal (origin: signal requires it), got {source_signal!r}")
        return 1

    people = fm.get("people", "")
    if EXPECTED_ATTENDEE not in people:
        print(f"FAIL: expected people to include [[{EXPECTED_ATTENDEE}]], got {people!r} in {proposal_path}")
        return 1

    for lifecycle_field in ("confirmed-on", "created-event-id"):
        value = fm.get(lifecycle_field, "")
        if value and value.lower() not in ("null", "~", ""):
            print(f"FAIL: expected {lifecycle_field} to be null/empty at creation, got {value!r} in {proposal_path}")
            return 1

    event = parse_proposed_event(text)

    if event.get("start") != EXPECTED_START:
        print(f"FAIL: expected proposed-event.start {EXPECTED_START!r}, got {event.get('start')!r} in {proposal_path}")
        return 1

    if event.get("end") != EXPECTED_END:
        print(f"FAIL: expected proposed-event.end {EXPECTED_END!r}, got {event.get('end')!r} in {proposal_path}")
        return 1

    attendees = event.get("attendees", "")
    if EXPECTED_ATTENDEE not in attendees:
        print(f"FAIL: expected proposed-event.attendees to include [[{EXPECTED_ATTENDEE}]], got {attendees!r} in {proposal_path}")
        return 1
    # Exactly one attendee for this fixture (a two-person 1:1 lunch).
    if attendees.count("[[") != 1:
        print(f"FAIL: expected exactly one attendee, got {attendees!r} in {proposal_path}")
        return 1

    print(f"PASS: found conforming event-proposal wake-up at {proposal_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
