#!/usr/bin/env python3
"""02-interaction-and-wakeups.py — T3 grader for 16-debrief-contradiction.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Checks the interaction file's exact filename and frontmatter against
`packages/core/contracts/interaction.md` and SKILL.md §5b's filename rule
(quoted verbatim in this case's prompt.md), and that `wakeups/` was left
untouched (empty is tolerated -- the `.gitkeep` fixture file -- but any
other file is a spurious wake-up this event does not warrant).
"""

import glob
import os
import re
import sys

EXPECTED_FILENAME = "2026-08-29-sofia-alvarez.md"


def frontmatter(text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}
    fm_lines = []
    for line in lines[1:]:
        if line.strip() == "---":
            break
        fm_lines.append(line)
    fm = {}
    for line in fm_lines:
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    return fm


def main():
    if len(sys.argv) < 2:
        print("usage: 02-interaction-and-wakeups.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    failures = []

    interactions_dir = os.path.join(worked, "interactions")
    if not os.path.isdir(interactions_dir):
        failures.append("no interactions/ dir in worked store")
    else:
        files = sorted(os.listdir(interactions_dir))
        if files != [EXPECTED_FILENAME]:
            failures.append(
                f"interactions/ contains {files!r}, expected exactly "
                f"[{EXPECTED_FILENAME!r}] per SKILL.md 5b's "
                f"<date>-<primary-person-slug> filename rule"
            )
        else:
            path = os.path.join(interactions_dir, EXPECTED_FILENAME)
            with open(path) as f:
                text = f.read()
            fm = frontmatter(text)
            if fm.get("schema_version", "") != "1.0.0":
                failures.append(
                    f"schema_version={fm.get('schema_version', '')!r}, expected '1.0.0'"
                )
            if fm.get("date", "") != "2026-08-29":
                failures.append(f"date={fm.get('date', '')!r}, expected '2026-08-29'")
            people = fm.get("people", "")
            if "[[sofia-alvarez]]" not in people:
                failures.append(
                    f"people={people!r} does not contain '[[sofia-alvarez]]'"
                )
            if fm.get("calendar-event", "") != "null":
                failures.append(
                    f"calendar-event={fm.get('calendar-event', '')!r}, expected 'null'"
                )
            if fm.get("source-capture", "") != "20260829T170000Z-manual-d40a":
                failures.append(
                    f"source-capture={fm.get('source-capture', '')!r}, expected "
                    f"'20260829T170000Z-manual-d40a'"
                )

    wakeups_dir = os.path.join(worked, "wakeups")
    if os.path.isdir(wakeups_dir):
        spurious = [
            p
            for p in glob.glob(os.path.join(wakeups_dir, "*"))
            if os.path.basename(p) != ".gitkeep"
        ]
        if spurious:
            failures.append(
                f"wakeups/ has spurious file(s) this event does not warrant: "
                f"{[os.path.basename(p) for p in spurious]!r}"
            )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: interactions/2026-08-29-sofia-alvarez.md filed with correct "
        "frontmatter; wakeups/ untouched"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
