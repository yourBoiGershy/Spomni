#!/usr/bin/env python3
"""01-dismissed-correctly.py — T3 grader for decline-files-silently.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Per packages/attention/skills/event-confirm/SKILL.md's step 4 (decline
path) and packages/attention/scripts/proposal-confirm.sh's decline
semantics, an explicit decline in the conversation must:
  - set status: dismissed
  - set dismiss-reason to one of the wakeup.md 1.2.0 enum values
    (not-now, not-this-person, not-this-signal-type, already-handled)
  - leave confirmed-on and created-event-id both null (decline never
    touches the calendar-write invariant fields)
  - change nothing else in the file: same schema_version, id, due, people,
    why, origin, source-signal, fired-on, acted-on, snooze-count,
    signal-type, kind, proposed-event, and both prose sections
    byte-identical to the seeded fixture, per SKILL.md step 4's "no new
    artifact beyond the dismissed wake-up file itself" and wakeup.md's "the
    dismissed wake-up file is itself the record: no retry, no second
    artifact."

Hand-derived expectation (from
packages/attention/tests/fixtures/event-confirm/decline-files-silently/
wakeups/2026-08-31-theo-bramwell.md and the prompt's decline utterance,
"I already grabbed a coffee with Theo yesterday ... no need for a separate
lunch"): the only two lines in the frontmatter block that may differ from
the seeded file are `status:` and `dismiss-reason:`; every other line
(both `---` fences, every other frontmatter field, and the entire prose
below) must be byte-identical.
"""

import os
import re
import sys

TARGET = os.path.join("wakeups", "2026-08-31-theo-bramwell.md")
VALID_REASONS = {"not-now", "not-this-person", "not-this-signal-type", "already-handled"}
ALLOWED_CHANGED_FIELDS = {"status", "dismiss-reason"}


def frontmatter_and_lines(text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}, lines
    fm = {}
    for line in lines[1:]:
        if line.strip() == "---":
            break
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    return fm, lines


def fixture_path():
    before_dir = os.environ.get("RA_EVAL_BEFORE_DIR", "")
    if before_dir:
        return os.path.join(before_dir, TARGET)
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(
        os.path.join(
            here, "..", "..", "..", "..", "tests", "fixtures", "event-confirm",
            "decline-files-silently", TARGET,
        )
    )


def main():
    if len(sys.argv) < 2:
        print("usage: 01-dismissed-correctly.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    worked_path = os.path.join(worked, TARGET)
    fixture_file = fixture_path()

    if not os.path.isfile(worked_path):
        print(f"FAIL: worked store is missing {TARGET} at {worked_path}")
        return 1
    if not os.path.isfile(fixture_file):
        print(f"FAIL: could not find fixture reference copy at {fixture_file}")
        return 1

    with open(worked_path) as f:
        worked_text = f.read()
    with open(fixture_file) as f:
        fixture_text = f.read()

    worked_fm, worked_lines = frontmatter_and_lines(worked_text)
    fixture_fm, fixture_lines = frontmatter_and_lines(fixture_text)

    if worked_fm.get("status") != "dismissed":
        print(f"FAIL: expected status: dismissed, got {worked_fm.get('status')!r}")
        return 1

    reason = worked_fm.get("dismiss-reason")
    if reason not in VALID_REASONS:
        print(
            f"FAIL: dismiss-reason {reason!r} is not one of the wakeup.md 1.2.0 enum "
            f"values {sorted(VALID_REASONS)}"
        )
        return 1

    confirmed = worked_fm.get("confirmed-on")
    if confirmed not in ("", "null", "~", None):
        print(f"FAIL: confirmed-on must stay null on a decline, got {confirmed!r}")
        return 1

    created = worked_fm.get("created-event-id")
    if created not in ("", "null", "~", None):
        print(f"FAIL: created-event-id must stay null on a decline, got {created!r}")
        return 1

    # Every other frontmatter field must be byte-identical to the seed.
    all_fields = set(worked_fm) | set(fixture_fm)
    unexpected_changes = []
    for field in sorted(all_fields):
        if field in ALLOWED_CHANGED_FIELDS:
            continue
        if worked_fm.get(field) != fixture_fm.get(field):
            unexpected_changes.append(
                f"{field}: fixture={fixture_fm.get(field)!r} worked={worked_fm.get(field)!r}"
            )
    if unexpected_changes:
        print("FAIL: field(s) changed beyond status/dismiss-reason:")
        for line in unexpected_changes:
            print(f"  - {line}")
        return 1

    # Line-level check: every line must match the fixture except lines that
    # are exactly the status:/dismiss-reason: field lines (covers ordering,
    # the two `---` fences, and both prose sections in one pass).
    if len(worked_lines) != len(fixture_lines):
        print(
            f"FAIL: line count changed ({len(fixture_lines)} -> {len(worked_lines)}) "
            f"-- decline must not add/remove any line"
        )
        return 1

    for i, (w_line, f_line) in enumerate(zip(worked_lines, fixture_lines)):
        if w_line == f_line:
            continue
        is_status_line = w_line.startswith("status:") and f_line.startswith("status:")
        is_reason_line = w_line.startswith("dismiss-reason:") and f_line.startswith("dismiss-reason:")
        if is_status_line or is_reason_line:
            continue
        print(f"FAIL: unexpected line change at line {i + 1}:\n  fixture: {f_line!r}\n  worked:  {w_line!r}")
        return 1

    print(
        f"PASS: {TARGET} is dismissed with dismiss-reason: {reason}, "
        f"confirmed-on/created-event-id still null, no other field or line changed"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
