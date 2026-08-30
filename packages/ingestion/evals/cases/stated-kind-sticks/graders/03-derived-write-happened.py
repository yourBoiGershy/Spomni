#!/usr/bin/env python3
"""03-derived-write-happened.py — T3 grader for stated-kind-sticks.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation: `sol-abernathy`'s person file starts with no
`kind`/`kind_source` field at all, and the pre-seeded judgment record for
her says `kind: friend`. Since her current `kind_source` is not
`stated-by-user`, SKILL.md Step 3's derived-kind-write path applies: her
person file must gain `kind: friend`, `kind_source: derived`, and
`kind_updated: 2026-08-29` in frontmatter, while every other (non-`kind*`)
line stays byte-identical to the fixture original — fact-based grading
only, never exact prose diffing of the kind_note itself.
"""

import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CASE_DIR = os.path.dirname(SCRIPT_DIR)
BEFORE_DIR = os.path.join(CASE_DIR, "before")

PERSON_REL = os.path.join("people", "sol-abernathy.md")


def non_kind_lines(text):
    return [
        line
        for line in text.splitlines()
        if not line.startswith("kind:")
        and not line.startswith("kind_note:")
        and not line.startswith("kind_source:")
        and not line.startswith("kind_expires:")
        and not line.startswith("kind_updated:")
    ]


def main():
    if len(sys.argv) < 2:
        print("usage: 03-derived-write-happened.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    worked_person = os.path.join(worked, PERSON_REL)
    before_person = os.path.join(BEFORE_DIR, PERSON_REL)

    failures = []

    if not os.path.isfile(worked_person):
        print(f"FAIL:\n  - {PERSON_REL}: missing from worked store")
        return 1

    with open(worked_person) as f:
        got = f.read()
    with open(before_person) as f:
        want = f.read()

    if "kind: friend" not in got:
        failures.append(f"{PERSON_REL}: missing 'kind: friend' in frontmatter")
    if "kind_source: derived" not in got:
        failures.append(
            f"{PERSON_REL}: missing 'kind_source: derived' in frontmatter"
        )
    if "kind_updated: 2026-08-29" not in got:
        failures.append(
            f"{PERSON_REL}: missing 'kind_updated: 2026-08-29' in frontmatter"
        )

    if non_kind_lines(got) != non_kind_lines(want):
        failures.append(
            f"{PERSON_REL}: non-kind* lines differ from before/ — only the "
            "kind*/frontmatter fields should have changed"
        )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        f"PASS: {PERSON_REL} gained the derived kind write (kind=friend, "
        "kind_source=derived, kind_updated=2026-08-29) with every other "
        "line unchanged"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
