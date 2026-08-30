#!/usr/bin/env python3
"""02-person-file-scoped-correctly.py — T3 grader for
15-debrief-commitment-other.

$1 = path to the worked store dir. $2 = result.json (unused).

Hand-derived expectation (from `packages/ingestion/tests/goldens/debrief/
09-commitment-by-other-party/before/people/jamie-oyelaran.md` and SKILL.md
§5a): the thread states nothing new about Jamie herself, so the only
permitted change to `people/jamie-oyelaran.md` is `last-touch: 2026-08-29`
— every other frontmatter field and every body section (`## Facts`,
`## Open threads`, `## Personal details`) must be byte-identical to the
`before/` fixture, and no other file under `people/` may be created,
deleted, or modified.
"""

import os
import re
import sys

BEFORE_JAMIE = """---
schema_version: 1.0.0
name: Jamie Oyelaran
org: Northbridge Legal
role: Contracts Manager
last-touch: 2026-08-10
tier: active
---

## Facts

- **[told-by-user]** Contracts Manager at Northbridge Legal (2026-08-10)

## Open threads

_none_

## Personal details

_none_
"""


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


def body_after_frontmatter(text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return text
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            return "\n".join(lines[i + 1:])
    return text


def main():
    if len(sys.argv) < 2:
        print("usage: 02-person-file-scoped-correctly.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    people_dir = os.path.join(worked, "people")
    failures = []

    entries = sorted(os.listdir(people_dir)) if os.path.isdir(people_dir) else []
    if entries != ["jamie-oyelaran.md"]:
        failures.append(f"people/ contains {entries!r}, expected exactly ['jamie-oyelaran.md']")

    path = os.path.join(people_dir, "jamie-oyelaran.md")
    if not os.path.isfile(path):
        failures.append("people/jamie-oyelaran.md missing from worked store")
    else:
        with open(path) as f:
            got_text = f.read()
        before_fm = frontmatter(BEFORE_JAMIE)
        got_fm = frontmatter(got_text)
        for key, before_val in before_fm.items():
            if key == "last-touch":
                if got_fm.get(key, "") != "2026-08-29":
                    failures.append(
                        f"last-touch={got_fm.get(key, '')!r}, expected '2026-08-29'"
                    )
                continue
            if got_fm.get(key, "") != before_val:
                failures.append(
                    f"frontmatter {key}={got_fm.get(key, '')!r} changed, expected unchanged {before_val!r}"
                )
        extra_keys = set(got_fm) - set(before_fm)
        if extra_keys:
            failures.append(f"unexpected new frontmatter keys: {sorted(extra_keys)!r}")

        got_body = body_after_frontmatter(got_text).strip()
        before_body = body_after_frontmatter(BEFORE_JAMIE).strip()
        if got_body != before_body:
            failures.append(
                "body sections (## Facts / ## Open threads / ## Personal details) "
                "changed, expected byte-identical to before/ "
                "(the thread states nothing new about Jamie herself)"
            )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print("PASS: people/jamie-oyelaran.md scoped to a last-touch-only update")
    return 0


if __name__ == "__main__":
    sys.exit(main())
