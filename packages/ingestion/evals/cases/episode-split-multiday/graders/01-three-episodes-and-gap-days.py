#!/usr/bin/env python3
"""01-three-episodes-and-gap-days.py — T3 grader for episode-split-multiday.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Fact-based, not byte-diff (a live LLM run's untouched-file bytes and prose
phrasing aren't guaranteed identical to a hand-authored golden even when
the filing is correct — see confirm-first-tier-writes/expected/README.md
for the same reasoning). This grader pins the structural, exact-value claim
that IS packages/ingestion/skills/debrief/SKILL.md's §5b-episodes rule:
a chat-message event whose genuine messages span three active UTC days
(2026-07-01, 2026-07-03, 2026-07-05, with 2026-07-02 and 2026-07-04 as gap
days with zero messages) files exactly one interaction per ACTIVE day, and
nothing at all for the gap days.

  1. Exactly three files exist at interactions/2026-07-0{1,3,5}-erin-
     fixture.md, each with correct frontmatter by value: schema_version
     1.0.0, matching date, people == [[erin-fixture]], calendar-event null,
     source-capture matching the triggering event's id (same value on all
     three, per point 2 of §5b-episodes).
  2. Each day's ## Summary contains that day's distinct content marker word
     (Waffles / kayak / pasta or recipe) -- confirms the summary is scoped
     to that day's exchange, not the whole thread lumped together.
  3. No interaction file exists for the two gap days, 2026-07-02 and
     2026-07-04 (any filename starting with those dates is a FAIL).
"""

import glob
import os
import re
import sys

EXPECTED_SOURCE_CAPTURE = "20260706T080000Z-beeper-in-whatsapp-ep7f"

EPISODES = [
    ("2026-07-01", ["waffles"]),
    ("2026-07-03", ["kayak"]),
    ("2026-07-05", ["pasta", "recipe"]),  # either word is an acceptable marker
]

GAP_DATES = ["2026-07-02", "2026-07-04"]


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


def section(body, name, stop_names):
    if name not in body:
        return ""
    tail = body.split(name, 1)[-1]
    for stop in stop_names:
        tail = tail.split(stop, 1)[0]
    return tail


def main():
    if len(sys.argv) < 2:
        print("usage: 01-three-episodes-and-gap-days.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    interactions_dir = os.path.join(worked, "interactions")
    failures = []

    if not os.path.isdir(interactions_dir):
        print(f"FAIL: no interactions/ dir in worked store {worked}")
        return 1

    for date, markers in EPISODES:
        path = os.path.join(interactions_dir, f"{date}-erin-fixture.md")
        if not os.path.isfile(path):
            failures.append(f"missing interactions/{date}-erin-fixture.md")
            continue
        with open(path) as f:
            fm, body = frontmatter(f.read())

        if fm.get("schema_version") != "1.0.0":
            failures.append(
                f"{date}-erin-fixture.md: schema_version={fm.get('schema_version')!r}, expected '1.0.0'"
            )
        if fm.get("date") != date:
            failures.append(f"{date}-erin-fixture.md: date={fm.get('date')!r}, expected {date!r}")
        people_raw = fm.get("people", "")
        if "[[erin-fixture]]" not in people_raw:
            failures.append(
                f"{date}-erin-fixture.md: people={people_raw!r}, expected [[erin-fixture]]"
            )
        cal_event = fm.get("calendar-event", "")
        if cal_event not in ("null", ""):
            failures.append(
                f"{date}-erin-fixture.md: calendar-event={cal_event!r}, expected null"
            )
        source_capture = fm.get("source-capture", "").strip('"').strip("'")
        if source_capture != EXPECTED_SOURCE_CAPTURE:
            failures.append(
                f"{date}-erin-fixture.md: source-capture={source_capture!r}, expected "
                f"{EXPECTED_SOURCE_CAPTURE!r} (same capture id on every episode)"
            )

        summary = section(body, "## Summary", ["## Commitments"]).lower()
        if not any(marker.lower() in summary for marker in markers):
            failures.append(
                f"{date}-erin-fixture.md: ## Summary does not mention any of "
                f"{markers!r} (that day's distinct content marker)"
            )

    for gap_date in GAP_DATES:
        matches = glob.glob(os.path.join(interactions_dir, f"{gap_date}-*"))
        if matches:
            failures.append(
                f"unexpected interaction file(s) for gap day {gap_date} (no genuine "
                f"messages that day, should not be an episode): {matches!r}"
            )

    all_files = sorted(glob.glob(os.path.join(interactions_dir, "*.md")))
    all_files = [f for f in all_files if os.path.basename(f) != ".gitkeep"]
    if len(all_files) != 3:
        failures.append(
            f"expected exactly 3 interaction files, found {len(all_files)}: "
            f"{[os.path.basename(f) for f in all_files]!r}"
        )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: exactly three interaction files, one per active day "
        "(2026-07-01, 2026-07-03, 2026-07-05), correct frontmatter and "
        "day-scoped summaries, no files for the two gap days"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
