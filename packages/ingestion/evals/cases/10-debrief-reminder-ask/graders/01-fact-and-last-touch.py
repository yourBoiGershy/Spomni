#!/usr/bin/env python3
"""01-fact-and-last-touch.py — T3 grader for 10-debrief-reminder-ask.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Fact-based, content-word tolerant. Checks:
  1. marcus-yeun.md's `## Facts` gained a bullet mentioning the client
     pitch (SKILL.md §5a: every new factual claim becomes an appended,
     tagged, dated Facts bullet).
  2. marcus-yeun.md's `last-touch` advanced to 2026-08-29 (SKILL.md §5a:
     last-touch always advances to the interaction's date).
"""

import os
import re
import sys


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
        print("usage: 01-fact-and-last-touch.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    failures = []

    path = os.path.join(worked, "people", "marcus-yeun.md")
    if not os.path.isfile(path):
        print("FAIL:\n  - people/marcus-yeun.md: file missing from worked store")
        return 1

    with open(path) as f:
        text = f.read()

    fm = frontmatter(text)
    if fm.get("last-touch", "") != "2026-08-29":
        failures.append(
            f"people/marcus-yeun.md: last-touch={fm.get('last-touch', '')!r}, "
            f"expected '2026-08-29' (the interaction's date, per SKILL.md §5a)"
        )

    facts_section = text.split("## Facts", 1)[-1].split("## Open threads", 1)[0]
    if "pitch" not in facts_section.lower():
        failures.append(
            "people/marcus-yeun.md: no ## Facts bullet mentions the client "
            "pitch (expected a new bullet about being swamped with a big "
            "client pitch)"
        )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: marcus-yeun.md has a pitch-related Facts bullet and "
        "last-touch: 2026-08-29"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
