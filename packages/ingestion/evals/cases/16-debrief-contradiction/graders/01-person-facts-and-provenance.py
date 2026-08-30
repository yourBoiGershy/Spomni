#!/usr/bin/env python3
"""01-person-facts-and-provenance.py — T3 grader for
16-debrief-contradiction.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Fact-based (not byte-diff) per this case's prompt.md and the two contracts
it quotes verbatim: `packages/core/contracts/person.md` (the only two valid
provenance tags are `told-by-user` and `inferred-public-web` — a live run
previously invented `[voice-note]`, which this grader must catch) and
`packages/ingestion/skills/debrief/SKILL.md` §5a (append-only Facts,
frontmatter is current-state, the new fact must carry the departure context
so the contradiction isn't silently dropped).
"""

import os
import re
import sys

VALID_TAGS = ("told-by-user", "inferred-public-web")


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


def facts_section(text):
    m = re.search(r"^## Facts\s*$(.*?)(^## |\Z)", text, re.MULTILINE | re.DOTALL)
    if not m:
        return []
    bullets = [
        line.strip() for line in m.group(1).splitlines() if line.strip().startswith("-")
    ]
    return bullets


def main():
    if len(sys.argv) < 2:
        print("usage: 01-person-facts-and-provenance.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    path = os.path.join(worked, "people", "sofia-alvarez.md")
    if not os.path.isfile(path):
        print(f"FAIL: {path} missing from worked store")
        return 1

    with open(path) as f:
        text = f.read()

    failures = []

    fm = frontmatter(text)
    if fm.get("org", "") != "Globex Corp":
        failures.append(f"frontmatter org={fm.get('org', '')!r}, expected 'Globex Corp'")
    if fm.get("role", "") != "VP of Sales":
        failures.append(f"frontmatter role={fm.get('role', '')!r}, expected 'VP of Sales'")
    if fm.get("last-touch", "") != "2026-08-29":
        failures.append(
            f"frontmatter last-touch={fm.get('last-touch', '')!r}, expected '2026-08-29'"
        )

    bullets = facts_section(text)

    old_bullet_present = any(
        "sales director at acme corp" in b.lower() and "(2026-06-01)" in b
        for b in bullets
    )
    if not old_bullet_present:
        failures.append(
            "old fact 'Sales Director at Acme Corp (2026-06-01)' is missing or was "
            "rewritten -- ## Facts is append-only per SKILL.md 5a, the old bullet "
            "must survive byte-for-byte"
        )

    # The new bullet: must carry a VALID provenance tag, the 2026-08-29 date,
    # AND mention both the new role/org and the old org (the contradiction
    # context) in the same bullet.
    new_bullet = None
    for b in bullets:
        if "globex" in b.lower() and "(2026-08-29)" in b:
            new_bullet = b
            break

    if new_bullet is None:
        failures.append(
            "no new Facts bullet dated (2026-08-29) mentioning Globex was found"
        )
    else:
        tag_match = re.match(r"^-\s*\*\*\[([^\]]+)\]\*\*", new_bullet)
        tag = tag_match.group(1) if tag_match else None
        if tag not in VALID_TAGS:
            failures.append(
                f"new Facts bullet has provenance tag {tag!r}, which is not one of "
                f"the two valid tags {VALID_TAGS!r} per person.md -- a human debrief "
                f"is always told-by-user; inventing a tag like 'voice-note' from the "
                f"capture event's `type:` field is the exact doctrine violation this "
                f"case exists to catch"
            )
        if "vp of sales" not in new_bullet.lower():
            failures.append(
                f"new Facts bullet does not mention 'VP of Sales': {new_bullet!r}"
            )
        if "acme" not in new_bullet.lower():
            failures.append(
                f"new Facts bullet does not carry the departure/contradiction context "
                f"(no mention of Acme): {new_bullet!r} -- SKILL.md 5a requires the "
                f"supersede context to be legible, not just the new role in isolation"
            )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: sofia-alvarez.md frontmatter updated to Globex Corp/VP of Sales/"
        "2026-08-29 last-touch; old Facts bullet preserved append-only; new Facts "
        "bullet carries a valid provenance tag and the Acme->Globex contradiction "
        "context"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
