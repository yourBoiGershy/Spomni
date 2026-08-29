#!/usr/bin/env python3
"""01-interaction-filed-correctly.py — T3 grader for
14-debrief-commitment-user.

$1 = path to the worked store dir (the `before/` copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's prompt.md and
`packages/ingestion/skills/debrief/SKILL.md` §5b/"Commitment extraction
(detail)", NOT from any run's output — per the eval-case contract's
golden-tests-before-prompts rule): filing the lunch-with-Marcus-Webb
capture event (`20260829T150000Z-manual-6e2f`) produces exactly one new
interaction file, named per §5b's `<date>-<primary-person-slug>` rule —
`interactions/2026-08-29-marcus-webb.md`, NOT
`2026-08-29-marcus-webb-lunch.md` or any other descriptive-suffix
variant — with `interaction.md` 1.0.0 frontmatter and a `## Commitments`
bullet owned by `user` (the user is the one who said "I said I'd send
him..."), naming the pitch deck, due `[by 2026-09-04]` (the explicit
stated date).
"""

import os
import re
import sys

EXPECTED_FILENAME = "2026-08-29-marcus-webb.md"

EXPECTED_FRONTMATTER = {
    "schema_version": "1.0.0",
    "date": "2026-08-29",
    "people": '["[[marcus-webb]]"]',
    "calendar-event": "null",
    "source-capture": "20260829T150000Z-manual-6e2f",
}


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
        print("usage: 01-interaction-filed-correctly.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    interactions_dir = os.path.join(worked, "interactions")
    failures = []

    if not os.path.isdir(interactions_dir):
        print(f"FAIL: no interactions/ dir in worked store {worked}")
        return 1

    entries = sorted(os.listdir(interactions_dir))
    if entries != [EXPECTED_FILENAME]:
        failures.append(
            f"interactions/ contains {entries!r}, expected exactly [{EXPECTED_FILENAME!r}] "
            f"(SKILL.md §5b: <date>-<primary-person-slug>, no descriptive suffix)"
        )

    path = os.path.join(interactions_dir, EXPECTED_FILENAME)
    if not os.path.isfile(path):
        failures.append(f"{EXPECTED_FILENAME}: file missing from worked store")
    else:
        with open(path) as f:
            body = f.read()
        fm = frontmatter(body)
        for key, expected_val in EXPECTED_FRONTMATTER.items():
            got = fm.get(key, "")
            if got != expected_val:
                failures.append(f"frontmatter {key}={got!r}, expected {expected_val!r}")

        if "## Summary" not in body:
            failures.append("missing '## Summary' section")
        if "## Commitments" not in body:
            failures.append("missing '## Commitments' section")
        else:
            commitments_section = body.split("## Commitments", 1)[1]
            bullet_re = re.compile(
                r"^-\s*user:.*pitch deck.*\[by 2026-09-04\]\s*$", re.IGNORECASE | re.MULTILINE
            )
            if not bullet_re.search(commitments_section):
                failures.append(
                    "no '## Commitments' bullet matching "
                    "'- user: ... pitch deck ... [by 2026-09-04]' "
                    f"(commitment must be owned by user, not [[marcus-webb]]); got section:\n{commitments_section!r}"
                )

    # wakeups/ must exist but hold no files (empty dir tolerated).
    wakeups_dir = os.path.join(worked, "wakeups")
    if os.path.isdir(wakeups_dir):
        stray = [
            f for f in os.listdir(wakeups_dir)
            if f != ".gitkeep"
        ]
        if stray:
            failures.append(f"wakeups/ has unexpected files: {stray!r}")

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(f"PASS: {EXPECTED_FILENAME} filed with correct frontmatter and user-owned commitment")
    return 0


if __name__ == "__main__":
    sys.exit(main())
