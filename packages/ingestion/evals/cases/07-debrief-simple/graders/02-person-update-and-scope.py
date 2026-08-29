#!/usr/bin/env python3
"""02-person-update-and-scope.py — T3 grader for 07-debrief-simple.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's prompt.md and SKILL.md §5a, NOT
from any run's output): `people/jordan-ellery.md`'s `last-touch` must move
to the interaction date (2026-08-29), and no file anywhere in the store
outside `interactions/2026-08-29-jordan-ellery.md` (new) and
`people/jordan-ellery.md` (modified) may differ from the `before/` fixture
-- in particular no `wakeups/*` file may appear, since this debrief carries
no explicit reminder ask.
"""

import filecmp
import os
import re
import sys

PERSON_PATH = "people/jordan-ellery.md"
INTERACTION_PATH = "interactions/2026-08-29-jordan-ellery.md"
ALLOWED_CHANGED = {PERSON_PATH, INTERACTION_PATH}


def frontmatter(text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}
    fm = {}
    for line in lines[1:]:
        if line.strip() == "---":
            break
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    return fm


def all_files(root):
    out = set()
    for dirpath, _dirnames, filenames in os.walk(root):
        for fname in filenames:
            if fname == ".gitkeep":
                continue
            full = os.path.join(dirpath, fname)
            rel = os.path.relpath(full, root)
            out.add(rel)
    return out


def main():
    if len(sys.argv) < 2:
        print("usage: 02-person-update-and-scope.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    before = os.environ.get("RA_EVAL_BEFORE_DIR", "")
    failures = []

    person_path = os.path.join(worked, PERSON_PATH)
    if not os.path.isfile(person_path):
        print(f"FAIL: {PERSON_PATH} missing from worked store")
        return 1

    with open(person_path) as f:
        fm = frontmatter(f.read())
    last_touch = fm.get("last-touch", "")
    if last_touch != "2026-08-29":
        failures.append(f"{PERSON_PATH}: last-touch={last_touch!r}, expected 2026-08-29")

    if before and os.path.isdir(before):
        before_files = all_files(before)
        worked_files = all_files(worked)

        new_files = worked_files - before_files
        for rel in sorted(new_files):
            if rel not in ALLOWED_CHANGED:
                failures.append(f"unexpected new file: {rel}")

        removed_files = before_files - worked_files
        for rel in sorted(removed_files):
            failures.append(f"file removed (never allowed): {rel}")

        for rel in sorted(before_files & worked_files):
            b = os.path.join(before, rel)
            w = os.path.join(worked, rel)
            if not filecmp.cmp(b, w, shallow=False):
                if rel not in ALLOWED_CHANGED:
                    failures.append(f"unexpected modification outside allowed scope: {rel}")

        wakeup_new = [f for f in new_files if f.startswith("wakeups/")]
        for rel in wakeup_new:
            failures.append(
                f"spurious wake-up created: {rel} — this debrief has no explicit "
                f"reminder ask, per SKILL.md's reminder-ask rule"
            )
    else:
        failures.append(f"could not resolve before/ dir for scope check: {before!r}")

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print("PASS: last-touch updated correctly; no writes outside the intended files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
