#!/usr/bin/env python3
"""01-interaction-file-shape.py — T3 grader for 08-debrief-rambly.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's prompt.md and
packages/core/contracts/interaction.md, NOT from any run's output): the
skill must create exactly one new interaction file at the fixed filename
`interactions/2026-08-29-priya-kessler.md` with frontmatter matching the
contract exactly, plus a non-empty `## Summary` that surfaces every topic
raised in the rambly, multi-topic debrief (the job move, the marathon, the
dog's surgery, the brother's visit) and a `## Commitments` section carrying
Priya's promise to send the race date.

This replaces the old whole-store byte-diff grader, which failed on any
prose phrasing difference from the golden — this grader checks structure
and content-bearing substance instead.
"""

import os
import re
import sys

EXPECTED_PATH = "interactions/2026-08-29-priya-kessler.md"
EXPECTED_FRONTMATTER = {
    "schema_version": "1.0.0",
    "date": "2026-08-29",
    "source-capture": "20260829T183000Z-manual-4d02",
}
EXPECTED_PEOPLE_SLUG = "priya-kessler"
# Every topic from the rambly debrief must surface in the summary somewhere.
SUMMARY_MUST_MENTION = ["northwind", "marathon", "biscuit", "brother"]
COMMITMENT_MUST_MENTION = ["race", "registration"]


def frontmatter(text):
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
    return fm, body


def section(body, heading):
    m = re.search(
        rf"^##\s*{re.escape(heading)}\s*$(.*?)(?=^##\s|\Z)",
        body,
        re.MULTILINE | re.DOTALL,
    )
    return m.group(1).strip() if m else None


def main():
    if len(sys.argv) < 2:
        print("usage: 01-interaction-file-shape.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    path = os.path.join(worked, EXPECTED_PATH)
    failures = []

    if not os.path.isfile(path):
        print(f"FAIL: expected interaction file missing: {EXPECTED_PATH}")
        return 1

    with open(path) as f:
        text = f.read()
    fm, body = frontmatter(text)

    for key, expected in EXPECTED_FRONTMATTER.items():
        got = fm.get(key, "")
        if got != expected:
            failures.append(f"frontmatter {key}={got!r}, expected {expected!r}")

    people = fm.get("people", "")
    if f"[[{EXPECTED_PEOPLE_SLUG}]]" not in people:
        failures.append(f"frontmatter people={people!r} missing [[{EXPECTED_PEOPLE_SLUG}]]")

    calendar_event = fm.get("calendar-event", "")
    if calendar_event not in ("null", ""):
        failures.append(f"frontmatter calendar-event={calendar_event!r}, expected null")

    summary = section(body, "Summary")
    if not summary:
        failures.append("## Summary is missing or empty")
    else:
        low = summary.lower()
        for word in SUMMARY_MUST_MENTION:
            if word not in low:
                failures.append(f"## Summary does not mention {word!r} (topic dropped): {summary!r}")

    commitments = section(body, "Commitments")
    if not commitments:
        failures.append("## Commitments is missing")
    else:
        low = commitments.lower()
        if not any(word in low for word in COMMITMENT_MUST_MENTION):
            failures.append(f"## Commitments does not mention the race/registration promise: {commitments!r}")

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(f"PASS: {EXPECTED_PATH} has contract-correct frontmatter and covers every topic")
    return 0


if __name__ == "__main__":
    sys.exit(main())
