#!/usr/bin/env python3
"""02-unlisted-ids-untouched.py — T3 grader for shard-mode-confined.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation: `shard-fixture-alex-checkin` and
`shard-fixture-jamie-update` do NOT appear in
`./store/data-ingestion/shards/shard-1.ids` — this shard run is not
responsible for them and must produce ZERO writes traceable to either:

  - no entry for either id in any ledger, main or per-shard,
  - no `interactions/*.md` file traceable to either via `source-capture`,
  - `people/alex-rivera.md` and `people/jamie-torres.md` byte-identical to
    the fixture (no touch at all, per the person-write confinement rule).

Fact-based only: file-existence, ledger-content, and byte-identity checks.
"""

import glob
import os
import re
import sys

UNLISTED_IDS = ["shard-fixture-alex-checkin", "shard-fixture-jamie-update"]

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CASE_DIR = os.path.dirname(SCRIPT_DIR)
BEFORE_DIR = os.path.join(CASE_DIR, "before")


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
        print("usage: 02-unlisted-ids-untouched.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    failures = []

    all_ledgers = glob.glob(os.path.join(worked, "data-ingestion", "*.log"))
    for ledger in sorted(all_ledgers):
        ids = read_lines(ledger)
        for uid in UNLISTED_IDS:
            if uid in ids:
                failures.append(
                    f"{os.path.relpath(ledger, worked)} contains '{uid}' — an "
                    f"id not in shard-1.ids must never be logged by this "
                    f"shard run"
                )

    interactions_dir = os.path.join(worked, "interactions")
    for path in sorted(glob.glob(os.path.join(interactions_dir, "*.md"))):
        with open(path) as f:
            text = f.read()
        sc = source_capture(text)
        if sc in UNLISTED_IDS:
            failures.append(
                f"{os.path.basename(path)}: source-capture={sc!r} — an "
                f"interaction file was created for an id outside this shard"
            )

    for person_rel in (
        os.path.join("people", "alex-rivera.md"),
        os.path.join("people", "jamie-torres.md"),
    ):
        worked_person = os.path.join(worked, person_rel)
        before_person = os.path.join(BEFORE_DIR, person_rel)
        if not os.path.isfile(worked_person):
            failures.append(f"{person_rel}: missing from worked store")
            continue
        with open(worked_person) as f:
            got = f.read()
        with open(before_person) as f:
            want = f.read()
        if got != want:
            failures.append(
                f"{person_rel}: byte content changed — this person is not a "
                f"participant of any event in shard-1.ids, so shard mode "
                f"must never touch their file"
            )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: unlisted ids produced zero writes — no ledger entry, no "
        "interaction file, alex-rivera.md and jamie-torres.md byte-identical "
        "to the fixture"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
