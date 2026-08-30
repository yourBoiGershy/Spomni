#!/usr/bin/env python3
"""03-eligible-event-filed.py — T3 grader for triage-held-respected.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation: `triage-held-fixture-eligible`'s id appears in
neither ledger, so batch mode's exclusion does not apply to it — it must
be filed normally:

  - `data-ingestion/debrief-filed.log` gains exactly one new entry for it,
  - `interactions/2026-08-20-morgan-alvarez.md` exists with
    `source-capture: triage-held-fixture-eligible` and
    `people: ["[[morgan-alvarez]]"]`,
  - `people/morgan-alvarez.md` gained at least one new `## Facts` bullet
    (this eval doesn't grade exact prose, only that the person file was
    actually touched by the filing, per the fact-based-grading rule).

Fact-based only: file-existence and ledger/frontmatter-field checks.
"""

import os
import re
import sys

ELIGIBLE_ID = "triage-held-fixture-eligible"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CASE_DIR = os.path.dirname(SCRIPT_DIR)
BEFORE_DIR = os.path.join(CASE_DIR, "before")


def read_lines(path):
    if not os.path.isfile(path):
        return []
    with open(path) as f:
        return [line.rstrip("\n") for line in f if line.strip()]


def main():
    if len(sys.argv) < 2:
        print("usage: 03-eligible-event-filed.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    failures = []

    # 1. debrief-filed.log gained exactly one entry for the eligible id.
    filed_log = os.path.join(worked, "data-ingestion", "debrief-filed.log")
    filed_ids = read_lines(filed_log)
    count = filed_ids.count(ELIGIBLE_ID)
    if count != 1:
        failures.append(
            f"debrief-filed.log has {count} entries for '{ELIGIBLE_ID}' "
            f"(expected exactly 1 — the eligible event must be filed)"
        )

    # 2. The interaction file exists, with the right source-capture + people link.
    interaction_path = os.path.join(
        worked, "interactions", "2026-08-20-morgan-alvarez.md"
    )
    if not os.path.isfile(interaction_path):
        failures.append(
            "interactions/2026-08-20-morgan-alvarez.md: missing — the "
            "eligible event must be filed as a new interaction"
        )
    else:
        with open(interaction_path) as f:
            text = f.read()
        sc = re.search(r"^source-capture:\s*(\S+)\s*$", text, re.MULTILINE)
        if not sc or sc.group(1) != ELIGIBLE_ID:
            failures.append(
                f"interactions/2026-08-20-morgan-alvarez.md: source-capture="
                f"{sc.group(1) if sc else None!r}, expected {ELIGIBLE_ID!r}"
            )
        if "[[morgan-alvarez]]" not in text:
            failures.append(
                "interactions/2026-08-20-morgan-alvarez.md: missing "
                "'[[morgan-alvarez]]' person link"
            )

    # 3. people/morgan-alvarez.md was actually updated (new Facts bullet,
    # not byte-identical to the fixture's original).
    person_rel = os.path.join("people", "morgan-alvarez.md")
    worked_person = os.path.join(worked, person_rel)
    before_person = os.path.join(BEFORE_DIR, person_rel)
    if not os.path.isfile(worked_person):
        failures.append(f"{person_rel}: missing from worked store")
    else:
        with open(worked_person) as f:
            got = f.read()
        with open(before_person) as f:
            want = f.read()
        if got == want:
            failures.append(
                f"{person_rel}: byte-identical to the fixture original — "
                f"the eligible event's new fact was never applied"
            )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        f"PASS: eligible event '{ELIGIBLE_ID}' filed normally — new "
        f"debrief-filed.log entry, new interaction with the right "
        f"source-capture/people link, person file updated"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
