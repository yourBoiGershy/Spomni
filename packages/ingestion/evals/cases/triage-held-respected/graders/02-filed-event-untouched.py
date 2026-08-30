#!/usr/bin/env python3
"""02-filed-event-untouched.py — T3 grader for triage-held-respected.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation: `triage-held-fixture-filed`'s id is pre-seeded
in `data-ingestion/debrief-filed.log` (filed in a prior session; its
result, `interactions/2026-08-01-sam-quill.md`, already exists in the
fixture). Per SKILL.md's batch-mode exclusion ("not in debrief-filed.log
AND not in triage-held.log"), this event must be skipped entirely on this
pass:

  - `debrief-filed.log` still contains the id exactly once (no duplicate
    line from a re-file),
  - the pre-existing interaction file for it is byte-identical to the
    fixture's original (no re-write, no second interaction file created
    for the same capture id),
  - `people/sam-quill.md` is byte-identical to the fixture's original (no
    re-applied person update).

Fact-based only: file-existence, ledger-content, and byte-identity checks.
"""

import os
import sys

FILED_ID = "triage-held-fixture-filed"

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
        print("usage: 02-filed-event-untouched.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    failures = []

    # 1. debrief-filed.log: exactly one entry for the pre-filed id.
    filed_log = os.path.join(worked, "data-ingestion", "debrief-filed.log")
    filed_ids = read_lines(filed_log)
    count = filed_ids.count(FILED_ID)
    if count != 1:
        failures.append(
            f"debrief-filed.log has {count} entries for '{FILED_ID}' "
            f"(expected exactly 1 — no re-file, no duplicate line)"
        )

    # 2. The pre-existing interaction file is untouched.
    interaction_rel = os.path.join("interactions", "2026-08-01-sam-quill.md")
    worked_interaction = os.path.join(worked, interaction_rel)
    before_interaction = os.path.join(BEFORE_DIR, interaction_rel)
    if not os.path.isfile(worked_interaction):
        failures.append(f"{interaction_rel}: missing from worked store")
    else:
        with open(worked_interaction) as f:
            got = f.read()
        with open(before_interaction) as f:
            want = f.read()
        if got != want:
            failures.append(
                f"{interaction_rel}: byte content changed — the already-filed "
                f"event's interaction must not be re-written"
            )

    # 3. people/sam-quill.md is untouched.
    person_rel = os.path.join("people", "sam-quill.md")
    worked_person = os.path.join(worked, person_rel)
    before_person = os.path.join(BEFORE_DIR, person_rel)
    if not os.path.isfile(worked_person):
        failures.append(f"{person_rel}: missing from worked store")
    else:
        with open(worked_person) as f:
            got = f.read()
        with open(before_person) as f:
            want = f.read()
        if got != want:
            failures.append(
                f"{person_rel}: byte content changed — the already-filed "
                f"event's person file must not be re-touched"
            )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        f"PASS: pre-filed event '{FILED_ID}' untouched — debrief-filed.log "
        f"has exactly one entry, its interaction and person file are "
        f"byte-identical to the fixture"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
