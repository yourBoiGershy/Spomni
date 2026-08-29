#!/usr/bin/env python3
"""01-confirm-adjust-written-correctly.py — T3 grader for
confirm-first-tier-writes.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's prompt.md, NOT from any run's
output — per the eval-case contract's golden-tests-before-prompts rule):
the simulated conversation has exactly two people with an explicit
confirm/adjust reply —

  hana-oduya  : confirmed the suggested tier verbatim -> tier: close
  victor-lang : adjusted away from the suggested `active` -> tier: inner-circle

Per packages/ingestion/skills/onboarding-seed/SKILL.md's Step 6 and
packages/ingestion/specs/stated-preference-filing.md (a).2, both are a
plain frontmatter `tier` overwrite on the already-existing person file --
this grader checks exactly those two files land the exact expected value,
nothing looser (e.g. an adjusted tier that isn't the one the user actually
named would be as wrong as no write at all).
"""

import os
import re
import sys

EXPECTED = {
    "hana-oduya.md": "close",
    "victor-lang.md": "inner-circle",
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
        print("usage: 01-confirm-adjust-written-correctly.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    people_dir = os.path.join(worked, "people")

    if not os.path.isdir(people_dir):
        print(f"FAIL: no people/ dir in worked store {worked}")
        return 1

    failures = []
    for fname, expected_tier in EXPECTED.items():
        path = os.path.join(people_dir, fname)
        if not os.path.isfile(path):
            failures.append(f"{fname}: file missing from worked store")
            continue
        with open(path) as f:
            fm = frontmatter(f.read())
        got = fm.get("tier", "")
        if got != expected_tier:
            failures.append(
                f"{fname}: tier={got!r}, expected tier={expected_tier!r}"
            )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        f"PASS: confirmed/adjusted tiers written exactly as specified "
        f"({', '.join(f'{k}={v}' for k, v in EXPECTED.items())})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
