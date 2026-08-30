#!/usr/bin/env python3
"""01-interaction-file-and-last-touch.py — T3 grader for
09-debrief-multi-person-chat.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Fact-based, not byte-diff (a live LLM run's untouched-file bytes and prose
phrasing aren't guaranteed identical to a hand-authored golden even when
the filing is correct — see confirm-first-tier-writes/expected/README.md
for the same reasoning). This grader checks the two structural, exact-value
facts this case pins per packages/core/contracts/interaction.md (1.0.0) and
SKILL.md's §5a `last-touch` rule:

  1. Exactly one interaction file exists at the contract's filename
     convention `<date>-<primary-person-slug>.md`, i.e.
     `interactions/2026-08-29-nadia-okafor.md` (Nadia is primary — the
     first-listed participant-hint), with frontmatter fields that are
     correct by *value*, not just present: schema_version, date, both
     people linked, calendar-event null, source-capture matching the
     triggering event's id.
  2. Both nadia-okafor.md and sam-vartan.md have last-touch: 2026-08-29 --
     SKILL.md's §5a rule that last-touch always advances to the
     interaction's date, regardless of what else changed.
"""

import os
import re
import sys

EXPECTED_SOURCE_CAPTURE = "20260829T200000Z-beeper-in-whatsapp-9a41"
INTERACTION_PATH = "interactions/2026-08-29-nadia-okafor.md"


def frontmatter(text):
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}, ""
    fm_lines = []
    body_start = 1
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            body_start = i + 1
            break
        fm_lines.append(line)
    # Handles both inline scalars/flow-lists (`key: value`, `key: [a, b]`,
    # `key: ["a", "b"]`) and block-style YAML lists (`key:` on its own line
    # followed by `  - item` lines) -- a filing pass may emit either shape
    # for a list field like `people`, and both are valid YAML.
    fm = {}
    last_key = None
    for line in fm_lines:
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if m:
            key, val = m.group(1), m.group(2).strip()
            fm[key] = val
            last_key = key
            continue
        item_m = re.match(r"^\s*-\s*(.*)$", line)
        if item_m and last_key is not None:
            fm[last_key] = (fm.get(last_key, "") + " " + item_m.group(1).strip()).strip()
    body = "\n".join(lines[body_start:])
    return fm, body


def main():
    if len(sys.argv) < 2:
        print("usage: 01-interaction-file-and-last-touch.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    failures = []

    interaction_file = os.path.join(worked, INTERACTION_PATH)
    if not os.path.isfile(interaction_file):
        failures.append(
            f"missing {INTERACTION_PATH} (expected filename "
            f"<date>-<primary-person-slug>.md with Nadia, the first-listed "
            f"participant-hint, as primary)"
        )
    else:
        with open(interaction_file) as f:
            fm, _ = frontmatter(f.read())

        if fm.get("schema_version") != "1.0.0":
            failures.append(
                f"{INTERACTION_PATH}: schema_version={fm.get('schema_version')!r}, expected '1.0.0'"
            )
        if fm.get("date") != "2026-08-29":
            failures.append(f"{INTERACTION_PATH}: date={fm.get('date')!r}, expected '2026-08-29'")

        people_raw = fm.get("people", "")
        if "[[nadia-okafor]]" not in people_raw or "[[sam-vartan]]" not in people_raw:
            failures.append(
                f"{INTERACTION_PATH}: people={people_raw!r}, expected both "
                f"[[nadia-okafor]] and [[sam-vartan]] linked"
            )

        cal_event = fm.get("calendar-event", "")
        if cal_event not in ("null", ""):
            failures.append(
                f"{INTERACTION_PATH}: calendar-event={cal_event!r}, expected null "
                f"(no linked calendar event for this chat-message capture)"
            )

        source_capture = fm.get("source-capture", "").strip('"').strip("'")
        if source_capture != EXPECTED_SOURCE_CAPTURE:
            failures.append(
                f"{INTERACTION_PATH}: source-capture={source_capture!r}, expected "
                f"{EXPECTED_SOURCE_CAPTURE!r} (the triggering capture event's id)"
            )

    for fname in ("nadia-okafor.md", "sam-vartan.md"):
        path = os.path.join(worked, "people", fname)
        if not os.path.isfile(path):
            failures.append(f"people/{fname}: file missing from worked store")
            continue
        with open(path) as f:
            fm, _ = frontmatter(f.read())
        got = fm.get("last-touch", "")
        if got != "2026-08-29":
            failures.append(
                f"people/{fname}: last-touch={got!r}, expected '2026-08-29' "
                f"(the interaction's date, per SKILL.md §5a)"
            )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: interactions/2026-08-29-nadia-okafor.md has correct "
        "frontmatter, and both participants' last-touch is 2026-08-29"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
