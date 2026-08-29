#!/usr/bin/env python3
"""02-wakeup-created.py — T3 grader for 10-debrief-reminder-ask.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

This is the "Reminder-ask -> wake-up entry" section of SKILL.md pinned as
executable code: the debrief's "Remind me to follow up with him in three
weeks" is an explicit first-person reminder ask, so filing it must produce
exactly one wakeups/*.md entry, due 2026-09-19 (2026-08-29 + 21 days) for
marcus-yeun, conforming to packages/core/contracts/wakeup.md (1.2.0), and
must produce no other, spurious wake-up files (the before/ fixture's
wakeups/ dir starts empty apart from .gitkeep).
"""

import glob
import os
import re
import sys

EXPECTED_DUE = "2026-09-19"
EXPECTED_SLUG = "marcus-yeun"


def frontmatter(text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}, ""
    fm_lines = []
    body_start = 1
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            body_start = i + 1
            break
        fm_lines.append(line)
    # Handles both inline scalars/flow-lists and block-style YAML lists
    # (`key:` on its own line followed by `  - item` lines) -- wakeup-add.sh
    # or a hand-filed entry may emit either shape for `people`.
    fm = {}
    last_key = None
    for line in fm_lines:
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if m:
            key, val = m.group(1), m.group(2).strip()
            fm[key] = val
            last_key = key
            continue
        item_m = re.match(r"^\s*-\s*(.*)$", line)
        if item_m and last_key is not None:
            fm[last_key] = (fm.get(last_key, "") + " " + item_m.group(1).strip()).strip()
    body = "\n".join(lines[body_start:])
    return fm, body


def main():
    if len(sys.argv) < 2:
        print("usage: 02-wakeup-created.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    wakeups_dir = os.path.join(worked, "wakeups")
    failures = []

    if not os.path.isdir(wakeups_dir):
        print("FAIL:\n  - no wakeups/ dir in worked store")
        return 1

    wakeup_files = sorted(
        p for p in glob.glob(os.path.join(wakeups_dir, "*.md"))
    )

    if len(wakeup_files) == 0:
        failures.append(
            "no wakeups/*.md entry was created at all -- an explicit "
            "reminder ask ('Remind me to follow up... in three weeks') "
            "must produce exactly one via wakeup-add.sh"
        )
    elif len(wakeup_files) > 1:
        failures.append(
            f"expected exactly one wakeups/*.md entry, found "
            f"{len(wakeup_files)}: {[os.path.basename(p) for p in wakeup_files]}"
        )

    for path in wakeup_files:
        fname = os.path.basename(path)
        with open(path) as f:
            text = f.read()
        fm, body = frontmatter(text)

        if fm.get("due", "") != EXPECTED_DUE:
            failures.append(
                f"wakeups/{fname}: due={fm.get('due', '')!r}, expected "
                f"{EXPECTED_DUE!r} (2026-08-29 + three weeks / 21 days)"
            )

        people = fm.get("people", "")
        if f"[[{EXPECTED_SLUG}]]" not in people:
            failures.append(
                f"wakeups/{fname}: people={people!r}, expected to include "
                f"[[{EXPECTED_SLUG}]]"
            )

        if fm.get("status", "") != "pending":
            failures.append(f"wakeups/{fname}: status={fm.get('status', '')!r}, expected 'pending'")

        if fm.get("origin", "") != "user-ask":
            failures.append(
                f"wakeups/{fname}: origin={fm.get('origin', '')!r}, expected "
                f"'user-ask' (explicit request, never signal/standing)"
            )

        why = fm.get("why", "")
        if not why.strip("\"'"):
            failures.append(f"wakeups/{fname}: why is empty, expected a one-line trigger")

        if not body.strip() or "## Context" not in text:
            failures.append(f"wakeups/{fname}: missing required ## Context body section")

        source_signal = fm.get("source-signal", "")
        if source_signal not in ("null", ""):
            failures.append(
                f"wakeups/{fname}: source-signal={source_signal!r}, expected "
                f"null (only required non-null for origin: signal)"
            )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        f"PASS: exactly one wakeups/*.md entry, due {EXPECTED_DUE}, for "
        f"{EXPECTED_SLUG}, with valid wakeup.md 1.2.0 frontmatter"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
