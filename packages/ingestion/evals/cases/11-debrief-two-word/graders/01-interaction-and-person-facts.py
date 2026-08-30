#!/usr/bin/env python3
"""01-interaction-and-person-facts.py — T3 grader for 11-debrief-two-word.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Fact-based grading, replacing a full-tree byte-diff (which was too brittle —
whitespace/prose phrasing in `## Summary` legitimately varies run to run).
Per SKILL.md sections 2-5 and packages/core/contracts/interaction.md /
person.md, this case's expected outcome (hand-derived from prompt.md, not
from any run's output):

- interactions/2026-08-29-dana-kowalski.md is created (filename per SKILL.md
  section 5b's `<date>-<primary-person-slug>.md` rule — NEVER the capture
  event's own id, 20260829T151000Z-manual-2c9f).
- Its frontmatter is exact: schema_version 1.0.0, date 2026-08-29,
  people ["[[dana-kowalski]]"], calendar-event null,
  source-capture 20260829T151000Z-manual-2c9f.
- Both fixed body sections are present, `## Commitments` is exactly `_none_`
  (bare two-word debrief, no commitment stated).
- people/dana-kowalski.md gets exactly one change: last-touch advances to
  2026-08-29. Every other frontmatter field and every body section (Facts,
  Open threads, Personal details) is untouched from the before/ fixture —
  a thin debrief invents nothing.
"""

import os
import re
import sys

INTERACTION_REL = "interactions/2026-08-29-dana-kowalski.md"
WRONG_INTERACTION_REL = "interactions/20260829T151000Z-manual-2c9f.md"
PERSON_REL = "people/dana-kowalski.md"

EXPECTED_INTERACTION_FM = {
    "schema_version": "1.0.0",
    "date": "2026-08-29",
    "people": '["[[dana-kowalski]]"]',
    "calendar-event": "null",
    "source-capture": "20260829T151000Z-manual-2c9f",
}

# Byte-identical before/ state for the parts of the person file that must
# NOT change (everything except last-touch).
BEFORE_PERSON_FM = {
    "schema_version": "1.0.0",
    "name": "Dana Kowalski",
    "org": "Freelance",
    "role": "Illustrator",
    "tags": "[friend]",
    "tier": "close",
}
BEFORE_PERSON_BODY = """## Facts

- **[told-by-user]** Freelance illustrator (2026-08-01)

## Open threads

_none_

## Personal details

_none_
"""


def split_frontmatter(text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}, text
    fm_lines = []
    body_start = None
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            body_start = i + 1
            break
        fm_lines.append(line)
    fm = {}
    for line in fm_lines:
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if m:
            fm[m.group(1)] = m.group(2).strip()
    body = "\n".join(lines[body_start:]) if body_start is not None else ""
    return fm, body.strip("\n") + "\n" if body_start is not None else ""


def main():
    if len(sys.argv) < 2:
        print("usage: 01-interaction-and-person-facts.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    failures = []

    wrong_path = os.path.join(worked, WRONG_INTERACTION_REL)
    if os.path.isfile(wrong_path):
        failures.append(
            f"{WRONG_INTERACTION_REL}: interaction filed under the capture "
            f"event's own id instead of the <date>-<slug>.md convention"
        )

    interaction_path = os.path.join(worked, INTERACTION_REL)
    if not os.path.isfile(interaction_path):
        failures.append(f"{INTERACTION_REL}: file missing from worked store")
    else:
        with open(interaction_path) as f:
            fm, body = split_frontmatter(f.read())
        for key, expected in EXPECTED_INTERACTION_FM.items():
            got = fm.get(key)
            if got != expected:
                failures.append(
                    f"{INTERACTION_REL}: frontmatter {key}={got!r}, expected {expected!r}"
                )
        extra_keys = set(fm.keys()) - set(EXPECTED_INTERACTION_FM.keys())
        if extra_keys:
            failures.append(
                f"{INTERACTION_REL}: unexpected frontmatter keys {sorted(extra_keys)}"
            )
        if "## Summary" not in body:
            failures.append(f"{INTERACTION_REL}: missing '## Summary' section")
        if "## Commitments" not in body:
            failures.append(f"{INTERACTION_REL}: missing '## Commitments' section")
        else:
            commitments = body.split("## Commitments", 1)[1].strip()
            if commitments != "_none_":
                failures.append(
                    f"{INTERACTION_REL}: Commitments={commitments!r}, expected '_none_'"
                )

    person_path = os.path.join(worked, PERSON_REL)
    if not os.path.isfile(person_path):
        failures.append(f"{PERSON_REL}: file missing from worked store")
    else:
        with open(person_path) as f:
            fm, body = split_frontmatter(f.read())
        for key, expected in BEFORE_PERSON_FM.items():
            got = fm.get(key)
            if got != expected:
                failures.append(
                    f"{PERSON_REL}: frontmatter {key}={got!r} changed from before/"
                    f" value {expected!r} — nothing but last-touch should move"
                )
        if fm.get("last-touch") != "2026-08-29":
            failures.append(
                f"{PERSON_REL}: last-touch={fm.get('last-touch')!r}, expected '2026-08-29'"
            )
        if body.strip() != BEFORE_PERSON_BODY.strip():
            failures.append(
                f"{PERSON_REL}: body sections changed from before/ — a thin "
                f"two-word debrief must add no new fact/thread/detail"
            )

    people_files = sorted(
        f for f in os.listdir(os.path.join(worked, "people")) if f.endswith(".md")
    ) if os.path.isdir(os.path.join(worked, "people")) else []
    if people_files != ["dana-kowalski.md"]:
        failures.append(
            f"people/: unexpected file set {people_files}, expected only "
            f"['dana-kowalski.md'] (no new person should be created)"
        )

    interactions_files = sorted(
        f for f in os.listdir(os.path.join(worked, "interactions")) if f.endswith(".md")
    ) if os.path.isdir(os.path.join(worked, "interactions")) else []
    if interactions_files != ["2026-08-29-dana-kowalski.md"]:
        failures.append(
            f"interactions/: unexpected file set {interactions_files}, expected "
            f"only ['2026-08-29-dana-kowalski.md']"
        )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: interactions/2026-08-29-dana-kowalski.md filed with exact "
        "interaction-1.0.0 frontmatter/sections; person file unchanged "
        "except last-touch"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
