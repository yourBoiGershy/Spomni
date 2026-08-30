#!/usr/bin/env python3
"""01-held-event-zero-writes.py — T3 grader for triage-held-respected.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's prompt.md and fixture, NOT from
any run's output — per the eval-case contract's golden-tests-before-
prompts rule): `triage-held-fixture-held`'s id is pre-seeded in
`data-ingestion/triage-held.log` (a prior triage-inbox.sh hold under
`noreply-marketing`). Per SKILL.md's batch-mode exclusion, it must produce
ZERO store writes:

  - no `data-ingestion/debrief-filed.log` entry for it (ever — a held
    event is not filed by batch mode, only an explicit single-event
    override supersedes a hold, and this case never runs one),
  - no `interactions/*.md` file traceable to it via `source-capture`,
  - no new `people/*.md` file created for a person that appeared only in
    this held event's content (this fixture's held event mentions no
    resolvable person at all, so any new people/*.md beyond the fixture's
    original two is itself already a violation, checked here too).

Fact-based only: file-existence and ledger-content checks, never prose-
diffing.
"""

import glob
import os
import re
import sys

HELD_ID = "triage-held-fixture-held"
ORIGINAL_PEOPLE = {"morgan-alvarez.md", "sam-quill.md"}


def read_lines(path):
    if not os.path.isfile(path):
        return []
    with open(path) as f:
        return [line.rstrip("\n") for line in f if line.strip()]


def source_capture(text):
    m = re.search(r"^source-capture:\s*(\S+)\s*$", text, re.MULTILINE)
    return m.group(1) if m else None


def main():
    if len(sys.argv) < 2:
        print("usage: 01-held-event-zero-writes.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    failures = []

    # 1. debrief-filed.log must never gain an entry for the held id.
    filed_log = os.path.join(worked, "data-ingestion", "debrief-filed.log")
    filed_ids = read_lines(filed_log)
    if HELD_ID in filed_ids:
        failures.append(
            f"debrief-filed.log contains '{HELD_ID}' — a held event must never "
            f"be filed by batch mode"
        )

    # 2. No interactions/*.md may trace back to the held event's capture id.
    interactions_dir = os.path.join(worked, "interactions")
    for path in sorted(glob.glob(os.path.join(interactions_dir, "*.md"))):
        with open(path) as f:
            text = f.read()
        sc = source_capture(text)
        if sc == HELD_ID:
            failures.append(
                f"{os.path.basename(path)}: source-capture={sc!r} — an "
                f"interaction file was created for the held event"
            )

    # 3. No new person file beyond the fixture's original two.
    people_dir = os.path.join(worked, "people")
    for path in sorted(glob.glob(os.path.join(people_dir, "*.md"))):
        fname = os.path.basename(path)
        if fname not in ORIGINAL_PEOPLE:
            failures.append(
                f"people/{fname}: unexpected new person file — the held "
                f"event's content must never have been read for filing"
            )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        f"PASS: held event '{HELD_ID}' produced zero store writes — no "
        f"debrief-filed.log entry, no interaction file, no new person file"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
