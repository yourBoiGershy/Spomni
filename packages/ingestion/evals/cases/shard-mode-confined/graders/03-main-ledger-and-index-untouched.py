#!/usr/bin/env python3
"""03-main-ledger-and-index-untouched.py — T3 grader for shard-mode-confined.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation, per SKILL.md §5c's shard-mode deviation: a shard
worker never touches the main `data-ingestion/debrief-filed.log` (its own
ledger is the per-shard `debrief-filed.shard-1.log` only) and never runs
`build-index.sh` — `index.json` stays exactly as seeded, byte-identical to
the fixture; the merge and the single post-wave rebuild are the wave
orchestrator's job, out of scope for this session.

Fact-based only: byte-identity checks against the fixture's `before/`.
"""

import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CASE_DIR = os.path.dirname(SCRIPT_DIR)
BEFORE_DIR = os.path.join(CASE_DIR, "before")


def main():
    if len(sys.argv) < 2:
        print(
            "usage: 03-main-ledger-and-index-untouched.py <worked-store-dir> "
            "[result.json]"
        )
        return 1

    worked = sys.argv[1]
    failures = []

    for rel in (
        os.path.join("data-ingestion", "debrief-filed.log"),
        "index.json",
    ):
        worked_path = os.path.join(worked, rel)
        before_path = os.path.join(BEFORE_DIR, rel)
        if not os.path.isfile(worked_path):
            failures.append(f"{rel}: missing from worked store")
            continue
        with open(worked_path) as f:
            got = f.read()
        with open(before_path) as f:
            want = f.read()
        if got != want:
            failures.append(
                f"{rel}: byte content changed — shard mode must never touch "
                f"this file (main ledger writes and index rebuilds are the "
                f"wave orchestrator's job, not this skill invocation's)"
            )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: main debrief-filed.log and index.json both byte-identical to "
        "the fixture — shard mode touched neither"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
