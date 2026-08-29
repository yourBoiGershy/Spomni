#!/usr/bin/env python3
"""02-person-update-and-no-wakeups.py — T3 grader for 08-debrief-rambly.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's prompt.md and SKILL.md's
reminder-ask rule, NOT from any run's output): `people/priya-kessler.md`'s
`last-touch` must move to the interaction date (2026-08-29), and -- this is
what this case actually regression-tests, per the checker's live-run
diagnosis that a prior run spawned a `wakeups/` file for every topic
mentioned -- **zero** files may appear under `wakeups/` anywhere in the
worked store. Nothing in this rambly debrief is a first-person imperative
reminder-ask (per SKILL.md: "Musing... creates no wake-up"); every topic
(job move, marathon, dog surgery, brother's visit) is a Facts/Open-threads/
Personal-details bullet at most, never a wake-up.

Also enforces scope: no file outside `interactions/2026-08-29-priya-kessler.md`
(new) and `people/priya-kessler.md` (modified) may differ from `before/`.
"""

import filecmp
import glob
import os
import re
import sys

PERSON_PATH = "people/priya-kessler.md"
INTERACTION_PATH = "interactions/2026-08-29-priya-kessler.md"
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
        print("usage: 02-person-update-and-no-wakeups.py <worked-store-dir> [result.json]")
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

    wakeup_files = sorted(glob.glob(os.path.join(worked, "wakeups", "*")))
    wakeup_files = [p for p in wakeup_files if os.path.basename(p) != ".gitkeep"]
    if wakeup_files:
        for p in wakeup_files:
            failures.append(
                f"spurious wake-up created: wakeups/{os.path.basename(p)} — this "
                f"debrief has no explicit first-person reminder ask, only topics/"
                f"musing, per SKILL.md's reminder-ask rule ('Musing... creates no "
                f"wake-up')"
            )

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
    else:
        failures.append(f"could not resolve before/ dir for scope check: {before!r}")

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print("PASS: last-touch updated correctly; no wake-ups spawned; no writes outside intended files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
